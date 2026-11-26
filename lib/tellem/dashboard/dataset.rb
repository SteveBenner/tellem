# frozen_string_literal: true

require_relative "../backends/rows"
require_relative "../record/kinds"
require_relative "../record/scope"
require_relative "../reports/health"
require_relative "../version"
require_relative "collector"

module Tellem
  module Dashboard
    module Dataset
      SCHEMA = "tellem.dashboard/v1"
      COUNTERS = Record::Kinds::COUNTERS
      WINDOWS = %w[24h 7d 30d].freeze
      USER_REPOSITORY = "outside repositories"
      UNKNOWN_PERSONA = "unknown"

      class Dictionary
        def initialize
          @values = {}
        end

        def note(value)
          known = value.is_a?(String) && !value.empty? ? value : nil
          @values[known] = true if known
          known
        end

        def list
          @list ||= @values.keys.sort
        end

        def [](value)
          @index ||= list.each_with_index.to_h
          value && @index.fetch(value)
        end
      end

      NAMES = %w[models agent_types efforts personas tools harnesses causes].freeze

      module_function

      def build(result)
        dict = NAMES.to_h { |name| [name, Dictionary.new] }
        sessions = result.files.filter_map { |file| file["session"] && file }.sort_by { |file| [file["scope"], file["key"]] }
        usage = usage_rows(result, sessions, dict)
        gaps = gap_rows(result, dict)
        hooks = hook_rows(result, dict)
        hook_gaps = result.hook_gaps.map { |row| [row["hour"], dict["causes"].note(row["cause"]), row["count"]] }
        noted = sessions.map { |file| note_session(file, dict) }
        {
          "schema" => SCHEMA,
          "tellem_version" => Tellem::VERSION,
          "as_of" => result.window.as_of.strftime(Collector::INSTANT),
          "since" => result.window.since.strftime(Collector::INSTANT),
          "hours" => Collector::HOURS,
          "share" => false,
          "counters" => COUNTERS,
          "dict" => dict.transform_values(&:list),
          "repos" => repos(result),
          "gone_repos" => result.gone,
          "sessions" => noted.map { |session| indexed_session(session, dict) },
          "usage" => usage.map { |row| indexed_usage(row, dict) }.sort_by { |row| row.first(7).map { |value| value || -1 } },
          "gaps" => indexed_gaps(gaps, dict),
          "hooks" => hooks.transform_values { |rows| rows.map { |row| [row[0], dict["harnesses"][row[1]], *row.drop(2)] } },
          "hook_gaps" => hook_gaps.map { |hour, cause, count| [hour, dict["causes"][cause], count] }
        }
      end

      def repos(result)
        names = result.scopes.map { |scope| repository_name(scope) }
        shared = names.tally.select { |_name, count| count > 1 }
        result.scopes.each_with_index.map do |scope, position|
          name = names[position]
          name = "#{name} (#{File.basename(File.dirname(scope['root']))})" if shared.key?(name)
          { "name" => name, "path" => scope["root"] }.merge(result.repos[position])
        end
      end

      def repository_name(scope)
        scope["kind"] == "user" ? USER_REPOSITORY : File.basename(scope["root"])
      end

      def note_session(file, dict)
        session = file["session"]
        agents = session["agents"].map do |agent|
          agent.merge("type" => dict["agent_types"].note(agent["type"]), "model" => dict["models"].note(agent["model"]),
                      "effort" => dict["efforts"].note(agent["effort"]))
        end
        session.merge(
          "repo" => file["scope"],
          "harness" => dict["harnesses"].note(session["harness"]),
          "agents" => agents,
          "calls" => session["calls"].map { |row| [row[0], dict["tools"].note(row[1]), *row.drop(2)] },
          "failures" => session["failures"].map { |row| [row[0], row[1], dict["tools"].note(row[2]), row[3]] }
        )
      end

      def indexed_session(session, dict)
        agents = session["agents"].map do |agent|
          agent.merge("type" => dict["agent_types"][agent["type"]], "model" => dict["models"][agent["model"]],
                      "effort" => dict["efforts"][agent["effort"]])
        end
        {
          "key" => session["key"],
          "repo" => session["repo"],
          "harness" => dict["harnesses"][session["harness"]],
          "label" => session["label"],
          "started" => session["started"],
          "ended" => session["ended"],
          "first" => session["first"],
          "last" => session["last"],
          "open" => session["open"],
          "home" => session["home"],
          "active_hours" => session["active_hours"],
          "agents" => agents,
          "calls" => session["calls"].map { |row| [row[0], dict["tools"][row[1]], *row.drop(2)] },
          "failures" => session["failures"].map { |row| [row[0], row[1], dict["tools"][row[2]], row[3]] }
        }
      end

      def usage_rows(result, sessions, dict)
        columns = result.columns
        places = session_places(sessions)
        agents = sessions.map { |file| file["session"]["agents"].each_with_index.to_h { |agent, index| [agent["key"], index] } }
        groups = {}
        result.usage.each do |tuple|
          session = place_of(tuple, columns, places, result.owners)
          next unless session

          agent = agents[session][tuple[columns.fetch("agent_key")]]
          next unless agent

          persona = tuple[columns.fetch("persona_key")]
          key = [
            result.window.hour(tuple[columns.fetch("ts")]), session, agent,
            dict["agent_types"].note(tuple[columns.fetch("subagent_type")]),
            dict["models"].note(tuple[columns.fetch("model")]),
            dict["efforts"].note(tuple[columns.fetch("effort")]),
            dict["personas"].note(persona == UNKNOWN_PERSONA ? nil : persona)
          ]
          add(groups[key] ||= [0, Array.new(COUNTERS.size), 0, 0], tuple, columns)
        end
        groups.map { |key, group| [*key, group[0], *group[1], group[3].positive? ? Backends::Rows.cost_usd(group[2]) : nil, group[3]] }
      end

      def session_places(sessions)
        sessions.each_with_index.with_object({}) do |(file, index), out|
          (out[file["key"]] ||= {})[file["scope"]] = index
        end
      end

      def place_of(tuple, columns, places, owners)
        homes = places[tuple[columns.fetch("session_key")]]
        return nil unless homes
        return homes.values.first if homes.size == 1

        homes[owners[tuple[columns.fetch("id")]]]
      end

      def add(group, tuple, columns)
        group[0] += 1
        sums = group[1]
        COUNTERS.each_with_index do |name, position|
          number = tuple[columns.fetch(name)]
          sums[position] = sums[position].to_i + number unless number.nil?
        end
        cost = tuple[columns.fetch("cost_usd")]
        return if cost.nil?

        group[2] += cost
        group[3] += 1
      end

      def indexed_usage(row, dict)
        hour, session, agent, type, model, effort, persona, *figures = row
        [hour, session, agent, dict["agent_types"][type], dict["models"][model], dict["efforts"][effort], dict["personas"][persona], *figures]
      end

      def gap_rows(result, dict)
        totals = Hash.new(0)
        result.files.group_by { |file| file["scope"] }.each do |scope, files|
          superseded = files.flat_map { |file| file["superseded_gaps"] }.to_h { |id| [id, true] }
          files.flat_map { |file| file["gaps"] }.uniq(&:first).each do |id, hour, cause, harness, count|
            next if superseded.key?(id)

            totals[[hour, scope, dict["causes"].note(cause), dict["harnesses"].note(harness)]] += count
          end
        end
        totals
      end

      def indexed_gaps(totals, dict)
        rows = totals.map { |(hour, scope, cause, harness), count| [hour, scope, dict["causes"][cause], dict["harnesses"][harness], count] }
        rows.sort_by { |row| row.map { |value| value || -1 } }
      end

      def hook_rows(result, dict)
        samples = hook_samples(result, dict)
        WINDOWS.each_with_index.to_h do |window, bucket|
          inside = samples.select { |key, _count| key[3] <= bucket }
          overall = hook_groups(inside, nil)
          by_repo = inside.group_by { |key, _count| key[0] }.sort_by(&:first).flat_map { |repo, list| hook_groups(list, repo) }
          [window, overall + by_repo]
        end
      end

      def hook_samples(result, dict)
        result.files.each_with_object(Hash.new(0)) do |file, out|
          file["hooks"].each do |harness, event, bucket, value, count|
            out[[file["scope"], dict["harnesses"].note(harness), event, bucket, value]] += count
          end
        end
      end

      def hook_groups(list, repo)
        return [] if list.empty?

        groups = list.group_by { |key, _count| [key[1], key[2]] }.sort_by { |(harness, event), _list| [harness.to_s, event] }
        [hook_row(repo, nil, nil, list), *groups.map { |(harness, event), members| hook_row(repo, harness, event, members) }]
      end

      def hook_row(repo, harness, event, list)
        values = list.flat_map { |key, count| Array.new(count, key[4]) }.sort
        [repo, harness, event, values.size, Reports::Health.rank(values, 50), Reports::Health.rank(values, 99), values.last]
      end
    end
  end
end
