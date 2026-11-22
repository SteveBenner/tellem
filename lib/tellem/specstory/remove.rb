# frozen_string_literal: true

require_relative "../authority/switch"
require_relative "../config/resolver"
require_relative "../deriver/emit"
require_relative "../errors"
require_relative "../ids"
require_relative "anchor"
require_relative "plan"
require_relative "startup"
require_relative "state"

module Tellem
  module Specstory
    module Remove
      EVENT = "tellem.specstory.removed"
      DRIFT_EVENT = "tellem.specstory.drift_removed"
      WRITER = "specstory_writer"

      module_function

      def plan(history:, prevent:, link_targets:)
        Plan.build(history: history, prevent: prevent, link_targets: link_targets)
      end

      def open_plans
        receipts = State.receipts
        closed = receipts.select { |record| record["phase"] == "complete" }.to_h { |record| [record["plan_id"], true] }
        receipts.select { |record| record["phase"] == "plan" && !closed[record["plan_id"]] }
      end

      def apply(history:, prevent:, link_targets:, confirm:, command:)
        stopped = Authority::Switch.reason
        if stopped
          raise CapabilityUnavailable.new("the authority stop switch is set (#{stopped}); specstory remove is halted, nothing was removed",
                                          next_command: "tellem authority resume", detail: { "cause" => "authority_stopped" })
        end

        outcome = State.exclusive do
          open = open_plans.find { |record| record["plan_id"] == confirm }
          if open
            result = run_items(open["plan_id"], open["items"], resumed: true)
            finish(open["plan_id"], open["source"], open["state"], result)
            next { "plan_id" => confirm, "resumed_only" => true, "removed" => result[:removed], "kept_after" => result[:kept] }
          end

          resumed = resume_open
          current = plan(history: history, prevent: prevent, link_targets: link_targets)
          unless confirm == current["plan_id"]
            raise ConfirmationRequired.new("confirmation id #{confirm} does not match the current plan #{current['plan_id']}; nothing was removed",
                                           next_command: "#{command} --confirm #{current['plan_id']}", detail: current)
          end

          payload = { "plan_id" => current["plan_id"], "applied_at" => Record::FS.rfc3339, "history" => history, "prevent" => prevent,
                      "link_targets" => current["link_targets"], "wrappers" => current["named_wrappers"], "roots" => current["roots"], "home" => current["home"] }
          State.append("phase" => "plan", "plan_id" => current["plan_id"], "source" => "remove", "items" => current["items"], "state" => payload)
          result = run_items(current["plan_id"], current["items"], resumed: false)
          finish(current["plan_id"], "remove", payload, result)
          current.merge("applied" => true, "removed" => result[:removed], "kept_after" => result[:kept], "resumed" => resumed)
        end
        raise Busy.new("another specstory removal holds the lock; nothing was removed", next_command: command) if outcome == :busy

        outcome
      end

      def resume_open
        return [] if Authority::Switch.off?

        open_plans.map do |record|
          result = run_items(record["plan_id"], record["items"], resumed: true)
          finish(record["plan_id"], record["source"], record["state"], result)
          { "plan_id" => record["plan_id"], "removed" => result[:removed], "kept" => result[:kept] }
        end
      end

      def resume
        outcome = State.exclusive { resume_open }
        outcome == :busy ? [] : outcome
      end

      def drift(items)
        plan_id = Ids.sha256(Ids.canonical_json([items, Record::FS.now_ns]))[0, 12]
        State.append("phase" => "plan", "plan_id" => plan_id, "source" => "drift", "items" => items)
        result = run_items(plan_id, items, resumed: false)
        finish(plan_id, "drift", nil, result)
        result.merge(plan_id: plan_id)
      end

      def run_items(plan_id, items, resumed:)
        records = State.receipts.select { |record| record["plan_id"] == plan_id }
        applied = records.select { |record| record["phase"] == "applied" }.to_h { |record| [record["index"], record] }
        pending = records.select { |record| record["phase"] == "pending" }.to_h { |record| [record["index"], true] }
        ios = {}
        result = { removed: 0, kept: [] }
        items.each_with_index do |item, index|
          if applied[index]
            tally(result, item, applied[index]["outcome"], applied[index]["cause"])
            next
          end
          receipt = "#{plan_id}-#{index}"
          State.append(receipt_fields(item).merge("phase" => "pending", "plan_id" => plan_id, "index" => index, "receipt_id" => receipt)) unless pending[index]
          outcome, cause = perform(item, ios, deep: resumed || pending[index] == true)
          State.append(receipt_fields(item).merge("phase" => "applied", "plan_id" => plan_id, "index" => index, "receipt_id" => receipt,
                                                  "outcome" => outcome.to_s, "cause" => cause))
          tally(result, item, outcome.to_s, cause)
        end
        result
      ensure
        ios&.each_value(&:close)
      end

      def tally(result, item, outcome, cause)
        if outcome == "kept"
          result[:kept] << { "path" => Plan.display(item), "cause" => cause }
        else
          result[:removed] += 1
        end
      end

      def receipt_fields(item)
        { "class" => item["class"], "kind" => item["kind"], "path" => Plan.display(item), "bytes" => item["bytes"], "sha256" => item["sha256"] }.compact
      end

      def perform(item, ios, deep:)
        return startup(item) if item["kind"] == "wrapper"

        base = item["base"]
        return [:kept, "link_changed"] if item["via"] && Anchor.real_path(item["via"]) != base

        io = ios[base] ||= open_base(base)
        return [:kept, "base_unavailable"] unless io

        fd = Anchor.fd_path(io)
        result = item["kind"] == "dir" ? Anchor.rmdir(fd, item) : Anchor.unlink(fd, item, deep: deep)
        case result
        when :removed then [:removed, nil]
        when :absent then [:removed, "absent"]
        else [:kept, item["kind"] == "dir" ? "not_empty_or_changed" : "changed"]
        end
      end

      def open_base(base)
        io = Anchor.open_directory(base)
        stat = Record::FS.lstat(base)
        return io if stat && !stat.symlink? && stat.ino == io.stat.ino && stat.dev == io.stat.dev

        io.close
        nil
      rescue SymlinkRefused, SystemCallError
        nil
      end

      def startup(item)
        case Startup.remove(item["file"], item["name"], item["shape"])
        when :removed then [:removed, nil]
        when :absent then [:removed, "absent"]
        else [:kept, "changed_retry_next_derive"]
        end
      end

      def finish(plan_id, source, payload, result)
        writer = nil
        if payload
          writer = pin_writer(plan_id)
          State.write(payload.merge("writer" => writer, "finished_at" => Record::FS.rfc3339))
        end
        State.append("phase" => "complete", "plan_id" => plan_id, "source" => source, "removed" => result[:removed], "kept" => result[:kept].size)
        Deriver::Emit.emit(source == "drift" ? DRIFT_EVENT : EVENT, { "plan_id" => plan_id, "removed" => result[:removed], "kept" => result[:kept].size })
        writer
      end

      def pin_writer(plan_id)
        row = Config.settings.explain(WRITER).find { |entry| entry[:layer] == "user" }
        current = row && row[:value]
        return { "value" => current, "changed" => false, "reason" => "the operator set #{WRITER} #{current}; tellem left it" } if current == "off"
        return { "value" => "on", "changed" => false, "reason" => "#{WRITER} was already on" } if current == "on"

        Config.set(WRITER, "on")
        { "value" => "on", "changed" => true, "reason" => "pinned on by SpecStory removal plan #{plan_id}, so readers of .specstory/history keep their input" }
      end
    end
  end
end
