import arsd.dom;
import std.stdio;
import std.algorithm;
import std.array;
import std.string;
import std.file;

void main()
{
    auto document = new Document();
    string content = std.file.readText(
            "Z:\\code\\github.com\\amdphreak\\gso-site\\old_site_downloaded_v14\\index.html");
    document.parseUtf8(content, true);

    writeln("Elements with text-align: center:");
    foreach (el; document.querySelectorAll("[style*='text-align: center']"))
    {
        writeln("Tag: ", el.tagName, " Style: ", el.getAttribute("style"));
        if (el.parentElement)
        {
            auto siblings = el.parentElement.children;
            auto index = siblings.countUntil(el) + 1;
            writeln("  Parent: ", el.parentElement.tagName, " (",
                    el.parentElement.getAttribute("id"), ") Index: ", index);
        }
        string text = el.innerText.strip;
        if (text.length > 50)
            text = text[0 .. 50] ~ "...";
        writeln("  Text: ", text);
        writeln("-------------------");
    }
}
