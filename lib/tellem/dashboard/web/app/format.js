(function () {
  "use strict";
  var T = window.TELLEM = window.TELLEM || {};
  var whole = new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 });
  var NOT_RECORDED = "not recorded";
  var UNKNOWN = "unknown";

  function pad(value) {
    return value < 10 ? "0" + value : String(value);
  }

  function missing(value) {
    return value === null || value === undefined;
  }

  function integer(value) {
    return missing(value) ? NOT_RECORDED : whole.format(value);
  }

  function compact(value) {
    if (missing(value)) {
      return NOT_RECORDED;
    }
    var units = [[1e9, "B"], [1e6, "M"], [1e3, "K"]];
    for (var i = 0; i < units.length; i += 1) {
      if (Math.abs(value) >= units[i][0] * 0.99995) {
        return (value / units[i][0]).toFixed(1) + units[i][1];
      }
    }
    return whole.format(value);
  }

  function duration(seconds) {
    if (missing(seconds)) {
      return NOT_RECORDED;
    }
    if (seconds > 0 && seconds < 1) {
      return "<1s";
    }
    var total = Math.round(seconds);
    if (total < 60) {
      return total + "s";
    }
    if (total < 3600) {
      return Math.floor(total / 60) + "m " + pad(total % 60) + "s";
    }
    var minutes = Math.round(total / 60);
    return Math.floor(minutes / 60) + "h " + pad(minutes % 60) + "m";
  }

  function exactDuration(seconds) {
    if (missing(seconds)) {
      return NOT_RECORDED;
    }
    return whole.format(Math.round(seconds)) + " seconds";
  }

  function monthDay(epoch) {
    var date = new Date(epoch * 1000);
    return pad(date.getMonth() + 1) + "-" + pad(date.getDate());
  }

  function clock(epoch) {
    var date = new Date(epoch * 1000);
    return pad(date.getHours()) + ":" + pad(date.getMinutes());
  }

  function dateTime(epoch) {
    return missing(epoch) ? NOT_RECORDED : monthDay(epoch) + " " + clock(epoch);
  }

  function fullTime(epoch) {
    if (missing(epoch)) {
      return NOT_RECORDED;
    }
    var date = new Date(epoch * 1000);
    return date.getFullYear() + "-" + monthDay(epoch) + " " + clock(epoch) + ":" + pad(date.getSeconds());
  }

  function utcOffset(epoch) {
    var minutes = -new Date(epoch * 1000).getTimezoneOffset();
    var size = Math.abs(minutes);
    return "UTC" + (minutes < 0 ? "-" : "+") + pad(Math.floor(size / 60)) + ":" + pad(size % 60);
  }

  function money(value) {
    if (missing(value)) {
      return NOT_RECORDED;
    }
    var digits = value > 0 && value < 0.01 ? 4 : 2;
    return "$" + value.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
  }

  function count(value, one, many) {
    return integer(value) + " " + (value === 1 ? one : many);
  }

  function shortKey(key, keys) {
    if (key === "main" || key.length <= 8) {
      return key;
    }
    var head = key.slice(0, 8);
    var clashes = (keys || []).filter(function (other) {
      return other !== key && other.slice(0, 8) === head;
    });
    return clashes.length ? key.slice(-8) : head;
  }

  T.format = {
    NOT_RECORDED: NOT_RECORDED,
    UNKNOWN: UNKNOWN,
    missing: missing,
    integer: integer,
    compact: compact,
    duration: duration,
    exactDuration: exactDuration,
    monthDay: monthDay,
    clock: clock,
    dateTime: dateTime,
    fullTime: fullTime,
    utcOffset: utcOffset,
    money: money,
    count: count,
    shortKey: shortKey
  };
})();
