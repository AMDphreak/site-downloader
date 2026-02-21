module archiver.profiles;

import std.file;
import std.path;
import std.process;
import std.stdio;
import std.json;

struct BrowserProfile {
    string name;
    string path;
    string browser;
}

BrowserProfile[] findChromiumProfiles() {
    BrowserProfile[] profiles;
    string localAppData = environment.get("LOCALAPPDATA");
    
    // Chrome
    string chromePath = buildPath(localAppData, "Google", "Chrome", "User Data");
    if (exists(chromePath)) {
        profiles ~= scanDir(chromePath, "Chrome");
    }

    // Edge
    string edgePath = buildPath(localAppData, "Microsoft", "Edge", "User Data");
    if (exists(edgePath)) {
        profiles ~= scanDir(edgePath, "Edge");
    }

    return profiles;
}

private BrowserProfile[] scanDir(string path, string browser) {
    BrowserProfile[] found;
    foreach(DirEntry entry; dirEntries(path, SpanMode.shallow)) {
        if (entry.isDir) {
            string profilePath = entry.name;
            string prefPath = buildPath(profilePath, "Preferences");
            if (exists(prefPath)) {
                string name = baseName(profilePath);
                // Try to read real profile name from Preferences
                try {
                    auto content = readText(prefPath);
                    auto json = parseJSON(content);
                    if ("profile" in json.object && "name" in json.object["profile"].object) {
                        name = json.object["profile"].object["name"].str;
                    }
                } catch (Exception e) {}
                
                found ~= BrowserProfile(name, profilePath, browser);
            }
        }
    }
    return found;
}
