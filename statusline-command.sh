#!/bin/sh
input=$(cat)
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
if [ -n "$model" ]; then
  if [ -n "$effort" ]; then
    printf "[%s | %s]" "$model" "$effort"
  else
    printf "[%s]" "$model"
  fi
fi
if [ -n "$used" ]; then
  printf " [ctx: %.0f%% used]" "$used"
fi
if [ -n "$five" ] || [ -n "$week" ]; then
  rate=""
  if [ -n "$five" ]; then
    rate="5h:$(printf '%.0f' "$five")%"
  fi
  if [ -n "$week" ]; then
    rate="$rate 7d:$(printf '%.0f' "$week")%"
  fi
  printf " [%s]" "$(echo "$rate" | sed 's/^ //')"
fi
