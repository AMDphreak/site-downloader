import webview;
import std.stdio;
import std.json;
import archiver;
import archiver.profiles;

void main() {
    auto wv = Webview(true);
    wv.setTitle("Site Archiver");
    wv.setSize(1200, 800, WindowHint.none);

    // Bind D functions to JS
    wv.bind("startArchive", (string url, string output, int depth) {
        writeln("Archive requested: ", url);
        auto sa = new SiteArchiver(url, output);
        sa.archive(depth);
        return JSONValue(["status": "ok"]);
    });

    wv.bind("getProfiles", () {
        auto profiles = findChromiumProfiles();
        JSONValue[] arr;
        foreach(p; profiles) {
            arr ~= JSONValue(["name": p.name, "browser": p.browser, "path": p.path]);
        }
        return JSONValue(arr);
    });

    // Frontend HTML (would ideally be in a separate file)
    string html = `
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                body { font-family: sans-serif; display: flex; height: 100vh; margin: 0; background: #1e1e1e; color: #fff; }
                #sidebar { width: 300px; border-right: 1px solid #333; padding: 20px; display: flex; flex-direction: column; }
                #preview { flex: 1; border: none; background: #fff; }
                input, button { padding: 10px; margin-bottom: 10px; background: #333; color: #fff; border: 1px solid #444; }
                button { background: #007acc; cursor: pointer; }
                .session { padding: 5px; border-bottom: 1px solid #333; font-size: 0.8em; }
            </style>
        </head>
        <body>
            <div id="sidebar">
                <h2>Site Archiver</h2>
                <input id="url" type="text" placeholder="https://example.com" />
                <button onclick="archive()">Download Site</button>
                <hr/>
                <h3>Sessions</h3>
                <div id="profiles"></div>
            </div>
            <iframe id="preview"></iframe>

            <script>
                async function archive() {
                    const url = document.getElementById('url').value;
                    const result = await startArchive(url, "archives", 2);
                    alert("Archive started!");
                }

                async function loadProfiles() {
                    const profiles = await getProfiles();
                    const container = document.getElementById('profiles');
                    profiles.forEach(p => {
                        const div = document.createElement('div');
                        div.className = 'session';
                        div.innerText = p.browser + ": " + p.name;
                        container.appendChild(div);
                    });
                }
                loadProfiles();
            </script>
        </body>
        </html>
    `;

    wv.setHtml(html);
    wv.run();
}
