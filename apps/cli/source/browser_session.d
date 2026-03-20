module browser_session;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.windows.registry;
import std.uri;

string getDefaultBrowser() {
    try {
        Key key = Registry.currentUser.getKey(`Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice`);
        string progId = key.getValue("ProgId").value_SZ;
        
        if (progId.canFind("Chrome")) return "chrome";
        if (progId.canFind("MSEdge")) return "edge";
        if (progId.canFind("Firefox")) return "firefox";
        if (progId.canFind("Brave")) return "brave";
        if (progId.canFind("Opera")) return "opera";
        if (progId.canFind("Vivaldi")) return "vivaldi";
        
        return "chrome"; // fallback
    } catch (Exception e) {
        return "chrome"; // fallback
    }
}

string getCookiesForDomain(string domain, string browserName = "auto", bool extractUrl = false) {
    string pyScript = `
import os
import sys
import json
try:
    import rookiepy
except ImportError:
    print("Error: rookiepy not installed", file=sys.stderr)
    sys.exit(1)

domain = sys.argv[1]
browser = sys.argv[2]
out_file = sys.argv[3] if len(sys.argv) > 3 else None
extract_url = domain == "EXTRACT_URL"

def get_last_used_browser_runtime():
    import ctypes
    import psutil
    
    user32 = ctypes.windll.user32
    
    browsers = {
        'chrome.exe': 'chrome',
        'msedge.exe': 'edge',
        'firefox.exe': 'firefox',
        'brave.exe': 'brave',
        'vivaldi.exe': 'vivaldi',
        'opera.exe': 'opera'
    }
    
    mru_pid = None
    mru_exe = None
    mru_hwnd = None
    
    def enum_windows_proc(hwnd, lParam):
        nonlocal mru_pid, mru_exe, mru_hwnd
        if user32.IsWindowVisible(hwnd) and user32.GetWindowTextLengthW(hwnd) > 0:
            pid = ctypes.c_ulong()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            try:
                p = psutil.Process(pid.value)
                exe_name = p.name().lower()
                if exe_name in browsers:
                    # Make sure we don't grab Cursor/VSCode which might be electron-based but not the actual browser
                    title = ctypes.create_unicode_buffer(512)
                    user32.GetWindowTextW(hwnd, title, 512)
                    if "Cursor" not in title.value and "Visual Studio Code" not in title.value:
                        mru_pid = pid.value
                        mru_exe = browsers[exe_name]
                        mru_hwnd = hwnd
                        return False # Stop enumerating
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
        return True
        
    EnumWindowsProc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_int, ctypes.c_int)
    user32.EnumWindows(EnumWindowsProc(enum_windows_proc), 0)
    
    if mru_pid:
        try:
            cmdline = psutil.Process(mru_pid).cmdline()
            profile_dir = "Default"
            for arg in cmdline:
                if arg.startswith('--profile-directory='):
                    profile_dir = arg.split('=', 1)[1].strip('"')
            return mru_exe, profile_dir, mru_hwnd
        except Exception:
            return mru_exe, "Default", mru_hwnd
            
    return None, None, None

def extract_url_from_hwnd(hwnd):
    try:
        import uiautomation as auto
        window = auto.WindowControl(searchDepth=1, Handle=hwnd)
        
        edit = window.EditControl(Name="Address and search bar")
        if not edit.Exists(0, 0):
            edit = window.EditControl(Name="Search or enter web address")
            
        if not edit.Exists(0, 0):
            doc = window.DocumentControl()
            if doc.Exists(0, 0):
                try:
                    val = doc.GetValuePattern().Value
                    if val and ("." in val or "localhost" in val):
                        if not val.startswith('http'): val = 'https://' + val
                        return val
                except: pass
                    
            pane = window.PaneControl()
            if pane.Exists(0, 0):
                try:
                    val = pane.GetValuePattern().Value
                    if val and ("." in val or "localhost" in val):
                        if not val.startswith('http'): val = 'https://' + val
                        return val
                except: pass
        
        if edit.Exists(0, 0):
            val = edit.GetValuePattern().Value
            if val and val.strip():
                if not val.startswith('http'): val = 'https://' + val
                return val
                
        for control, depth, _ in auto.WalkTree(window, getChildren=lambda c: c.GetChildren(), maxDepth=5):
            try:
                val = control.GetValuePattern().Value
                if val and ("." in val or "localhost" in val) and " " not in val:
                    if not val.startswith('http'): val = 'https://' + val
                    return val
            except: pass
            try:
                val = control.Name
                if val and ("." in val or "localhost" in val) and " " not in val and "/" in val and not val.endswith(".exe"):
                    if not val.startswith('http'): val = 'https://' + val
                    return val
            except: pass
    except Exception as e:
        print(f"URL extraction error: {e}", file=sys.stderr)
    return None

def get_chromium_paths(browser_name, profile_dir=None):
    local_app_data = os.environ.get('LOCALAPPDATA')
    paths = {
        'chrome': os.path.join(local_app_data, 'Google', 'Chrome', 'User Data'),
        'edge': os.path.join(local_app_data, 'Microsoft', 'Edge', 'User Data'),
        'brave': os.path.join(local_app_data, 'BraveSoftware', 'Brave-Browser', 'User Data'),
        'vivaldi': os.path.join(local_app_data, 'Vivaldi', 'User Data'),
        'opera': os.path.join(os.environ.get('APPDATA', ''), 'Opera Software', 'Opera Stable')
    }
    
    user_data = paths.get(browser_name)
    if not user_data or not os.path.exists(user_data):
        return None, None, None
        
    local_state_path = os.path.join(user_data, 'Local State')
    if not os.path.exists(local_state_path):
        return None, None, None
        
    try:
        with open(local_state_path, 'r', encoding='utf-8') as f:
            local_state = json.load(f)
            
            # Use provided profile_dir from runtime, or fallback to last_used in Local State
            last_used = profile_dir if profile_dir else local_state.get('profile', {}).get('last_used')
            
            profile_name = last_used
            if last_used and 'profile' in local_state and 'info_cache' in local_state['profile']:
                if last_used in local_state['profile']['info_cache']:
                    profile_name = local_state['profile']['info_cache'][last_used].get('name', last_used)
            
            if last_used:
                db_path = os.path.join(user_data, last_used, 'Network', 'Cookies')
                if not os.path.exists(db_path):
                    db_path_old = os.path.join(user_data, last_used, 'Cookies')
                    if os.path.exists(db_path_old):
                        db_path = db_path_old
                return local_state_path, db_path, profile_name
    except Exception as e:
        pass
    return None, None, None

runtime_profile = None
runtime_hwnd = None
if browser == "auto" or extract_url:
    try:
        import psutil
        runtime_browser, runtime_profile, runtime_hwnd = get_last_used_browser_runtime()
        if runtime_browser:
            browser = runtime_browser
        elif browser == "auto":
            browser = "chrome" # fallback
    except ImportError:
        print("Warning: psutil not installed, falling back to default browser", file=sys.stderr)
        if browser == "auto":
            browser = "chrome"

if extract_url:
    if runtime_hwnd:
        url = extract_url_from_hwnd(runtime_hwnd)
        if url:
            if out_file:
                with open(out_file, 'w', encoding='utf-8') as f:
                    f.write(f"URL_FOUND:{url}")
            else:
                print(f"URL_FOUND:{url}")
            sys.exit(0)
    print("ERROR_URL: Could not find active browser URL", file=sys.stderr)
    if out_file:
        with open(out_file, 'w', encoding='utf-8') as f:
            f.write("ERROR_URL")
    sys.exit(1)

try:
    cookies = []
    if browser in ['chrome', 'edge', 'brave', 'vivaldi', 'opera']:
        key_path, db_path, profile_name = get_chromium_paths(browser, runtime_profile)
        if key_path and db_path and os.path.exists(db_path):
            print(f"INFO: Detected last-used browser: {browser} (Profile: {profile_name})", file=sys.stderr)
            cookies = rookiepy.chromium_based(key_path, db_path, [domain])
        else:
            print(f"INFO: Detected last-used browser: {browser} (Default Profile)", file=sys.stderr)
            if browser == "chrome": cookies = rookiepy.chrome([domain])
            elif browser == "edge": cookies = rookiepy.edge([domain])
            elif browser == "brave": cookies = rookiepy.brave([domain])
            elif browser == "vivaldi": cookies = rookiepy.vivaldi([domain])
            elif browser == "opera": cookies = rookiepy.opera([domain])
    elif browser == "firefox":
        print(f"INFO: Detected last-used browser: firefox", file=sys.stderr)
        cookies = rookiepy.firefox([domain])
    else:
        cookies = rookiepy.load([domain])
    
    cookie_string = "; ".join([f"{c['name']}={c['value']}" for c in cookies])
    if out_file:
        with open(out_file, 'w', encoding='utf-8') as f:
            f.write(cookie_string)
    else:
        print(cookie_string)
except Exception as e:
    print(f"ERROR_EXTRACTING: {e}", file=sys.stderr)
    if out_file:
        with open(out_file, 'w', encoding='utf-8') as f:
            f.write(f"ERROR: {e}")
    sys.exit(1)
`;

    string tempDir = tempDir();
    string scriptPath = buildPath(tempDir, "extract_cookies.py");
    string outPath = buildPath(tempDir, "cookies_out.txt");
    if (exists(outPath)) remove(outPath);
    
    std.file.write(scriptPath, pyScript);
    
    if (extractUrl) {
        writeln("Attempting to extract URL from the active browser window...");
    } else {
        writeln("Extracting cookies for ", domain, "...");
    }
    stdout.flush();
    
    // Check if uv is available
    try {
        auto uvCheck = execute(["uv", "--version"]);
        if (uvCheck.status != 0) {
            writeln("Warning: 'uv' is not working correctly. Cannot automatically extract ", extractUrl ? "URL" : "cookies", ".");
            return "";
        }
    } catch (Exception e) {
        writeln("Warning: 'uv' is not installed or not in PATH. Cannot automatically extract ", extractUrl ? "URL" : "cookies", ".");
        if (!extractUrl) writeln("Please install uv (https://astral.sh/uv) or provide cookies manually with -c.");
        return "";
    }
    
    string targetDomain = extractUrl ? "EXTRACT_URL" : domain;
    
    try {
        auto result = execute(["uv", "run", "--with", "rookiepy", "--with", "psutil", "--with", "uiautomation", "python", scriptPath, targetDomain, browserName]);
        
        if (result.status != 0) {
            if (!extractUrl && (result.output.canFind("appbound encryption") || result.output.canFind("AppBound") || result.output.canFind("admin"))) {
                writeln("\n[!] Chrome/Edge v130+ requires Administrator privileges to extract cookies.");
                writeln("    Requesting elevation (please accept the UAC prompt)...");
                
                string[] psArgs = [
                    "powershell", "-NoProfile", "-Command",
                    "Start-Process", "-FilePath", "uv", 
                    "-ArgumentList", "@('run', '--with', 'rookiepy', '--with', 'psutil', '--with', 'uiautomation', 'python', '" ~ scriptPath.replace("\\", "\\\\") ~ "', '" ~ targetDomain ~ "', '" ~ browserName ~ "', '" ~ outPath.replace("\\", "\\\\") ~ "')", 
                    "-Verb", "RunAs", "-Wait", "-WindowStyle", "Hidden"
                ];
                
                auto elevResult = execute(psArgs);
                
                if (exists(outPath)) {
                    string cookies = readText(outPath).strip();
                    remove(outPath);
                    
                    if (cookies.startsWith("ERROR:")) {
                        writeln("Failed to extract cookies even after elevation: ", cookies);
                        return "";
                    }
                    
                    if (!cookies.empty) {
                        writeln("Successfully extracted cookies via Admin.");
                        return cookies;
                    }
                }
                writeln("Failed to extract cookies even after elevation.");
                return "";
            }
            
            writeln("Failed to extract ", extractUrl ? "URL" : "cookies", ":");
            writeln(result.output.strip());
            return "";
        }
        
        string output = result.output.strip();
        
        if (extractUrl) {
            if (output.startsWith("URL_FOUND:")) {
                return output[10..$];
            } else {
                writeln("Could not extract URL from active browser window.");
                return "";
            }
        }
        
        if (output.empty) {
            writeln("No cookies found for domain ", domain, " in ", browserName, ".");
        } else {
            writeln("Successfully extracted cookies.");
        }
        
        return output;
    } catch (Exception e) {
        writeln("Failed to execute uv process: ", e.msg);
        return "";
    }
}
