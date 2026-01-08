# Sway Desktop Environment Audit Report
**Date:** 2026-01-08
**Purpose:** Ensure productivity as primary desktop environment for PhD student

## Executive Summary

Your Sway configuration is solid and well-structured with excellent fundamentals: keyboard-driven workflow, proper screen locking, HiDPI support, and good application defaults. However, several critical productivity features are missing that would significantly enhance your workflow as a PhD student.

**Overall Assessment:** 7/10 - Good foundation, needs productivity enhancements

## What's Working Well ✓

### Strong Foundation
- **Tiling window manager** with proper keybindings following i3/Sway conventions
- **Multi-language keyboard support** (US, Arabic, Finnish)
- **HiDPI support** properly configured with appropriate DPI and cursor sizes
- **Screen locking** with swayidle and intelligent timeouts
- **Caffeine mode** to prevent sleep during presentations/long tasks
- **Password management** with Bitwarden (rbw) integration
- **Screenshot tool** with multiple capture modes and editing options
- **Wayland-native applications** (imv, foot, bemenu, zathura)

### Good Application Selection
- **Emacs** with comprehensive language support (Python, Go, Rust, LaTeX, Markdown, etc.)
- **Zathura** for PDF viewing with vim-style keybindings
- **Thunar** file manager with useful plugins
- **Ghostty terminal** as default
- **Chromium** as browser
- **Zoom** for video conferencing (university profile)

### Proper System Integration
- XDG portals configured for screensharing
- GNOME Keyring for credential storage
- PipeWire for modern audio
- NetworkManager with IWD
- Proper GTK/Qt theming

## Critical Missing Features ⚠

### 1. Screen Recording (HIGH PRIORITY)
**Impact:** Essential for creating presentations, demos, and tutorials common in PhD work

**Missing:**
- No screen recording tool configured
- No quick keybinding to start/stop recording

**Recommendations:**
```nix
# Add to extraPackages:
wf-recorder        # Simple Wayland screen recorder
obs-studio         # Full-featured recording/streaming (alternative)

# Suggested keybindings:
# Mod4+r - Start/stop recording
# Mod4+Shift+r - Record selection
```

### 2. Clipboard History Manager (HIGH PRIORITY)
**Impact:** Frequently copy-paste between papers, code, and documents

**Missing:**
- No clipboard history
- Can only paste most recent item
- Lost clipboard contents on application close

**Recommendations:**
```nix
# Add cliphist for Wayland clipboard management:
cliphist           # Wayland clipboard history

# Setup wl-paste --watch cliphist store
# Keybinding: Mod1+v to show history with bemenu
```

### 3. Status Bar Information (MEDIUM PRIORITY)
**Impact:** Need to see battery, WiFi, and system status at a glance

**Currently showing:**
- Volume
- Load
- Date/Time

**Missing:**
- Battery status and percentage (critical for laptops)
- WiFi signal strength and network name
- Disk space usage
- Memory usage
- CPU temperature

**Recommendations:**
Enable more i3status modules in `modules/graphics/sway/bar.nix:24-26`:
```nix
"battery all" = {
  enable = true;
  position = 2;
  settings = {
    format = "%status %percentage %remaining";
    status_chr = "⚡";
    status_bat = "🔋";
    status_full = "☻";
  };
};
"wireless _first_" = {
  enable = true;
  position = 3;
  settings.format_up = "📶 %essid %quality";
};
"disk /" = {
  enable = true;
  position = 4;
  settings.format = "💾 %avail";
};
"memory" = {
  enable = true;
  position = 5;
  settings = {
    format = "RAM: %used/%total";
    threshold_degraded = "10%";
  };
};
```

### 4. Workspace Management (MEDIUM PRIORITY)
**Impact:** Better organization of different research tasks/contexts

**Missing:**
- No workspace naming or labeling
- No automatic workspace assignment for applications
- No workspace-specific wallpapers or behaviors

**Recommendations:**
```nix
# In sway config:
keybindings = {
  # Named workspaces
  "${mod}+1" = "workspace number 1 Research";
  "${mod}+2" = "workspace number 2 Writing";
  "${mod}+3" = "workspace number 3 Code";
  "${mod}+4" = "workspace number 4 Communication";
  "${mod}+5" = "workspace number 5 Reading";
  # ...
};

assigns = {
  "1 Research" = [{ app_id = "^emacs$"; }];
  "4 Communication" = [
    { class = "^Zoom$"; }
    { class = "^Slack$"; }
    { app_id = "^element$"; }
  ];
};
```

### 5. Communication Tools (MEDIUM PRIORITY)
**Impact:** Collaboration with supervisors, colleagues, and research groups

**Currently configured:**
- Zoom (university profile only)

**Missing:**
- Slack (commented out in work profile)
- Element/Matrix for decentralized chat
- Signal for encrypted messaging
- Discord (if research community uses it)

**Recommendations:**
```nix
environment.systemPackages = with pkgs; [
  element-desktop    # Matrix client
  signal-desktop     # Encrypted messaging
  slack             # If needed for research groups
  discord           # If research community uses it
];
```

### 6. Scratchpad Configuration (MEDIUM PRIORITY)
**Impact:** Quick access to calculator, notes, terminal for temporary tasks

**Missing:**
- No scratchpad keybindings configured
- No applications assigned to scratchpad

**Recommendations:**
```nix
# Sway keybindings:
"${mod}+Shift+minus" = "move scratchpad";
"${mod}+minus" = "scratchpad show";

# Launch apps in scratchpad mode:
"${mod}+n" = "exec ghostty --class=scratchpad";  # Quick terminal
"${mod}+c" = "exec gnome-calculator";            # Calculator

# Float scratchpad apps:
for_window = [
  { app_id = "scratchpad"; } "floating enable, move scratchpad"
  { app_id = "org.gnome.Calculator"; } "floating enable, move scratchpad"
];
```

### 7. PDF Annotation Tools (MEDIUM PRIORITY)
**Impact:** Need to annotate papers, mark up drafts, review documents

**Currently:**
- Zathura is view-only (no annotation support)

**Recommendations:**
```nix
# Add PDF annotation tools:
xournalpp         # PDF annotation with stylus support
okular            # KDE PDF viewer with annotation
sioyek            # Research-focused PDF viewer with note-taking

# Or use existing tools differently:
# - Screenshots → Satty for quick annotations
# - GIMP for detailed markups
# Consider adding PDF-tools to Emacs for in-editor annotation
```

### 8. Focus Mode / Do Not Disturb (MEDIUM PRIORITY)
**Impact:** Deep work sessions require minimal distractions

**Missing:**
- No do-not-disturb mode for notifications
- No focus mode that hides bar or dims inactive windows
- Ianny (break reminder) is disabled

**Recommendations:**
```nix
# Enable ianny for ergonomic breaks:
systemd.user.services.ianny.enable = true;  # Currently line 59 is false

# Add dunst controls for DND:
keybindings = {
  "Mod4+n" = "exec dunstctl set-paused toggle && notify-send 'Do Not Disturb toggled'";
};

# Consider mako instead of dunst for better DND support:
# Or add notification control script for dunst
```

### 9. Screen Sharing Enhancements (LOW PRIORITY)
**Impact:** Remote presentations and collaboration

**Currently:**
- XDG portals configured for screensharing
- Should work with Zoom

**Potential Issues:**
- No confirmation which display/window being shared
- No indicator when sharing

**Recommendations:**
Monitor and add visual indicators if needed.

### 10. Reference Management (LOW PRIORITY)
**Impact:** Managing papers and citations for thesis work

**Missing:**
- Zotero or other reference manager
- BibTeX integration (may already be in Emacs)

**Recommendations:**
```nix
# Add reference management:
zotero            # Or zotero-beta from unstable
jabref            # Java-based BibTeX manager

# Emacs already has org-ref support likely
# Check Emacs config for citar/helm-bibtex
```

### 11. Auto-tiling Improvements (LOW PRIORITY)
**Impact:** Better automatic window layout

**Currently:**
- Standard Sway tiling (manual control)

**Recommendations:**
```nix
# Add autotiling script:
autotiling        # Automatically switch split direction

# Add to sway startup:
exec autotiling
```

### 12. Presentation Mode (LOW PRIORITY)
**Impact:** Clean screen during presentations/demos

**Missing:**
- Quick toggle to hide bar
- Presentation-optimized settings
- External display mirroring

**Recommendations:**
```nix
# Toggle bar visibility:
mode "presentation" = {
  # Bar hidden, caffeine on, notifications off
  "${mod}+Shift+p" = "mode default";
};

"${mod}+Shift+p" = "bar mode toggle; mode presentation";
```

## Specific File Changes Recommended

### Priority 1: Essential Productivity

1. **Add screen recording** - `modules/graphics/sway/default.nix`
2. **Add clipboard history** - `modules/graphics/wayland-services.nix`
3. **Improve status bar** - `modules/graphics/sway/bar.nix`
4. **Enable ianny breaks** - `modules/graphics/wayland-services.nix:59`

### Priority 2: Collaboration & Organization

5. **Add communication apps** - `modules/profiles/university.nix`
6. **Configure workspaces** - `modules/graphics/sway/default.nix`
7. **Add PDF annotation** - `modules/graphics/sway/applications.nix`

### Priority 3: Quality of Life

8. **Configure scratchpad** - `modules/graphics/sway/default.nix`
9. **Add focus mode/DND** - `modules/graphics/wayland-services.nix`
10. **Add reference manager** - `modules/profiles/university.nix`

## Additional Observations

### What Could Be Simplified

1. **Berkeley Mono font option** - Adds complexity with conditional logic everywhere
   - Consider committing to one font to simplify config

2. **Commented code** - Several commented sections (org-clock, printer configs)
   - Consider removing dead code or moving to separate files

### What's Over-Engineered

Nothing significant - the configuration is appropriately modular and maintainable.

### Missing Documentation

Consider adding comments in config files explaining:
- Why certain applications float automatically
- Purpose of specific keybindings
- Kanshi profile purposes for each host

## Recommended Implementation Order

### Phase 1: Critical Missing Features (Do First)
1. Add clipboard history manager (cliphist)
2. Add screen recording (wf-recorder)
3. Enhance status bar (battery, WiFi, memory)
4. Enable ergonomic breaks (ianny)

### Phase 2: Collaboration Tools
5. Add communication apps (Element, Signal)
6. Add PDF annotation (Xournalpp or okular)
7. Add reference manager (Zotero)

### Phase 3: Workflow Optimization
8. Configure named workspaces
9. Set up scratchpad
10. Add focus mode/DND controls
11. Add autotiling

## Conclusion

Your Sway setup has an excellent foundation with proper security, HiDPI support, and keyboard-driven workflow. The main gaps are in **daily productivity tools** (clipboard history, screen recording) and **collaboration features** (better status info, communication apps).

Implementing Phase 1 changes would bring this from a 7/10 to a 9/10 for PhD student productivity. The current setup is usable but missing quality-of-life features that save significant time daily.

## Quick Wins (< 5 minutes each)

1. Enable more i3status modules for battery and WiFi
2. Enable ianny for break reminders
3. Add Zotero to university profile
4. Add named workspace numbers
5. Configure scratchpad keybindings

These small changes would provide immediate value while you plan larger additions like clipboard history and screen recording.
