import Foundation
import WebKit

/// Fixes for sites that were only ever tried in Chromium and break in WebKit, each kept to the sites named for it. A fix that changed how
/// every page sees the browser's own objects could set off a site's checks for a browser that isn't what it says (a bot check compares
/// functions with the browser's own), so none of these runs anywhere it isn't needed.
enum SiteQuirks {
    /// A date written with spaces around it ("2026-12-21 ", what `"a ~ b".split("~")` leaves) is no date to WebKit, where Chromium
    /// reads past the spaces. CJ OnStyle's hotel list divides the total by the nights between two such dates and shows "NaN" a night.
    /// Only a string WebKit can't read and that has spaces around it is read again without them, so every date that worked still does.
    static let trimmedDates = Quirk(hosts: ["otour.cjonstyle.com"], source: """
    (() => {
      const NativeDate = Date;
      const readable = (value) => typeof value === 'string' && value !== value.trim() && Number.isNaN(NativeDate.parse(value)) ? value.trim() : value;
      const parse = { parse(value) { return NativeDate.parse(readable(value)); } }.parse;
      const patched = new Proxy(NativeDate, {
        construct(target, args, newTarget) {
          return Reflect.construct(target, args.length === 1 ? [readable(args[0])] : args, newTarget === patched ? target : newTarget);
        },
        get(target, key) { return key === 'parse' ? parse : Reflect.get(target, key, target); }
      });
      window.Date = patched;
    })();
    """)

    static let all = [trimmedDates]

    struct Quirk {
        /// The sites it is for, each with the hosts under it.
        let hosts: [String]
        let source: String

        func applies(to host: String) -> Bool {
            let host = host.lowercased()
            return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }

        /// The script as it is put in every page: it looks at where it is first and does nothing anywhere else.
        var script: String {
            let names = (try? JSONSerialization.data(withJSONObject: hosts)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return """
            (() => {
              const host = location.hostname.toLowerCase();
              if (!\(names).some(name => host === name || host.endsWith('.' + name))) return;
            \(source)
            })();
            """
        }
    }

    /// In the page's own world, before its scripts run: the fixes change what the page's code gets.
    static func install(in controller: WKUserContentController) {
        for quirk in all {
            controller.addUserScript(WKUserScript(source: quirk.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
    }
}
