on run argv
  set action to item 1 of argv
  set terminals to ""
  tell application "iTerm2"
    if action is "current" then
      if (count of windows) is 0 then return ""
      return tty of current session of current window
    end if
    repeat with w in windows
      set tabTTYs to tty of every session of every tab of w
      repeat with tabIndex from 1 to count of tabTTYs
        set sessionTTYs to item tabIndex of tabTTYs
        repeat with sessionIndex from 1 to count of sessionTTYs
          set terminalTTY to item sessionIndex of sessionTTYs
          if action is "list" then
            set terminals to terminals & terminalTTY & linefeed
          else if action is "focus" and terminalTTY is (item 2 of argv) then
            set t to tab tabIndex of w
            set s to session sessionIndex of t
            if tty of s is not terminalTTY then error "The iTerm2 layout changed. Try again."
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
