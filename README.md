# clicktrack
a vibe-coded solution for auto-click detection

## introduction
For years now, major game engines had one issue: input was bound to the client fps.
this means that, if you click, you'll need to wait for the next frame to render before the game can process the input.
that's an issue because it adds noise to solutions that would prevent auto-clickers. **clicktrack** fixes this!

## how to download?!?!?!
go to this link: https://github.com/coolpeter98/clicktrack/releases/
you will see downloads for windows (x64, ARM), linux (x64) and macos (apple silicon/arm64).

## running
on windows: extract the downloaded zip file and run the exe.
on linux: open a terminal to the directory of where you downloaded the file, then run `chmod +x linux_x86_64` and then `./linux_x86_64`
on mac: open a terminal to the directory of where you downloaded the file, then run `chmod +x macos_arm64` and then `./macos_arm64`

## limitation(s)
**mouse polling rate** still causes an unavoidable delay. it should be fine on mice with polling rate >= 1kHz though

## building
building is really straightforward, just clone the repo, install Zig, and run `zig build` in a terminal that is in the cloned directory. It should compile for your system automatically.
if you are still lazy, head to the [releases](https://github.com/coolpeter98/clicktrack/releases/) page for prebuilt binaries.

## malware?
if you're concerned about it being malware, the repo is open source, you can look for any traces of malware. the prebuilt binaries also do not have reverse-engineering measures such as obfuscation.
