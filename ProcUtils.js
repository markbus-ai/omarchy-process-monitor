// ProcUtils.js — pure helpers for the process-monitor plugin.
// No state, no QtQuick imports. All functions take explicit arguments.
.pragma library

function fmt(kb) {
  if (kb >= 1048576) return (kb / 1048576).toFixed(1) + "G"
  if (kb >= 1024) return (kb / 1024).toFixed(0) + "M"
  return kb + "K"
}

function usageColor(p) {
  if (p < 50) return "#33cc66"
  if (p < 75) return "#e6b800"
  if (p < 90) return "#f28c28"
  return "#f24040"
}

function usageColorDim(p) {
  if (p < 50) return "#1a3322"
  if (p < 75) return "#332d1a"
  if (p < 90) return "#33261a"
  return "#331a1a"
}

// Human-friendly name: dig through shell wrappers to the real binary.
function shortName(p) {
  if (!p || !p.cmdline || p.cmdline.length === 0) return (p && p.name) || "?"
  var parts = p.cmdline.split(" ")
  var bin = parts[0].split("/").pop()
  if ((bin === "zsh" || bin === "bash" || bin === "fish" || bin === "sh") && parts.length > 1) {
    for (var i = 1; i < parts.length; i++) {
      var c = parts[i].split("/").pop()
      if (c.length > 0 && c.charAt(0) !== "-") return c
    }
  }
  return bin
}

function procIcon(n) {
  var l = (n || "").toLowerCase()
  if (l.indexOf("firefox") >= 0 || l.indexOf("zen") >= 0 || l.indexOf("chrome") >= 0) return "󰈹"
  if (l.indexOf("code") >= 0 || l.indexOf("opencode") >= 0) return "󰘚"
  if (l.indexOf("docker") >= 0) return "󰡨"
  if (l.indexOf("node") >= 0) return "󰘐"
  if (l.indexOf("python") >= 0) return "󰌠"
  if (l.indexOf("zsh") >= 0 || l.indexOf("bash") >= 0) return "󰆍"
  if (l.indexOf("hyprland") >= 0) return "󰮯"
  if (l.indexOf("quickshell") >= 0) return "󰕙"
  if (l.indexOf("spotify") >= 0) return "󰎆"
  if (l.indexOf("kitty") >= 0 || l.indexOf("foot") >= 0 || l.indexOf("alacritty") >= 0) return "󰆍"
  if (l.indexOf("git") >= 0) return "󰊢"
  return "󰅧"
}

// RAM share of one node vs total system memory (0..100).
function sharePct(rssKb, totalMemGb) {
  if (!totalMemGb) return 0
  return (rssKb / (totalMemGb * 1048576)) * 100
}
