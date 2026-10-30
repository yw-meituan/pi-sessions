on run argv
  set action to item 1 of argv
  set terminals to ""
  tell application "iTerm2"
    if action is "current" then
      if (count of windows) is 0 then return ""
      return tty of current session of current window
    end if
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          set terminalTTY to tty of s
          if action is "list" then
            set terminals to terminals & terminalTTY & linefeed
          else if action is "focus" and terminalTTY is (item 2 of argv) then
            select s
            select t
            if miniaturized of w then set miniaturized of w to false
            select w
            activate
            return terminalTTY
          end if
        end repeat
      end repeat
    end repeat
  end tell
  if action is "list" then return terminals
  error "The matching iTerm2 window was not found. It may have been closed."
end run
