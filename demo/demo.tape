# vhs script -- regenerate the demo GIF headlessly:  vhs demo/demo.tape
# Produces assets/demo.gif (no screen recording needed).
Output assets/demo.gif

Set Shell bash
Set FontSize 18
Set Width 1180
Set Height 760
Set Padding 24
Set Theme "Catppuccin Mocha"
Set PlaybackSpeed 1.0

Hide
Type "cd $(git rev-parse --show-toplevel 2>/dev/null || pwd)"
Enter
Type "clear"
Enter
Show

Sleep 600ms
Type "DEMO_PACED=1 bash demo/demo.sh"
Sleep 500ms
Enter
Sleep 9s
Sleep 2s
