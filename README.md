# clicktrack
a vibe-coded solution for auto-click detection

## introduction
For years now, major game engines had one issue: input was bound to the client fps.
this means that, if you click, you'll need to wait for the next frame to render before the game can process the input.
that's an issue because it adds noise to solutions that would prevent auto-clickers. **clicktrack** fixes this!

## building
building is really straightforward, just clone the repo, install Zig, and run `zig build` in a terminal that is in the cloned directory. It should compile for your system automatically.
if you are still lazy, head to the [releases](https://github.com/coolpeter98/clicktrack/) page for prebuilt binaries.

## malware?
if you're concerned about it being malware, the repo is open source, you can look for any traces of malware. the prebuilt binaries also do not have reverse-engineering measures such as obfuscation.
