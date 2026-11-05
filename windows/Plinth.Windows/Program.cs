using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace Plinth.Windows
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            try
            {
                Dictionary<string, string> options = Parse(args);
                string provider = Get(options, "provider", "quark");
                string baseUrl = Get(options, "base", "http://127.0.0.1:8081/dav/" + provider + "/");
                string root = Get(
                    options,
                    "root",
                    Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                        "Plinth",
                        provider));
                string account = Get(options, "account", "plinth");
                string password = Get(options, "password", "plinth");

                if (options.ContainsKey("unregister"))
                {
                    SyncEngine.Unregister(root);
                    Console.WriteLine("[CloudWeft] unregistered: " + Path.GetFullPath(root));
                    return 0;
                }

                DavClient dav = new DavClient(baseUrl, account, password);
                using (SyncEngine engine = new SyncEngine(root, provider, dav))
                {
                    engine.Start();
                    Console.WriteLine("[CloudWeft] backend: " + baseUrl);
                    Console.WriteLine("[CloudWeft] Ctrl+C to stop.");

                    ManualResetEvent stop = new ManualResetEvent(false);
                    Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs eventArgs)
                    {
                        eventArgs.Cancel = true;
                        stop.Set();
                    };
                    stop.WaitOne();
                }
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("[CloudWeft] fatal: " + ex);
                return 1;
            }
        }

        private static Dictionary<string, string> Parse(string[] args)
        {
            Dictionary<string, string> result =
                new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < args.Length; i++)
            {
                string token = args[i];
                if (!token.StartsWith("--", StringComparison.Ordinal)) continue;
                string key = token.Substring(2);
                if (key == "unregister")
                {
                    result[key] = "true";
                    continue;
                }
                if (i + 1 >= args.Length)
                    throw new ArgumentException("Missing value for " + token);
                result[key] = args[++i];
            }
            return result;
        }

        private static string Get(Dictionary<string, string> options, string key, string fallback)
        {
            string value;
            return options.TryGetValue(key, out value) ? value : fallback;
        }
    }
}
