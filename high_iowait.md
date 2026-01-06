# High iowait Investigation and Fix

**Date:** 2026-01-06
**System:** anoa (Lenovo ThinkPad X1 Carbon Gen 13)
**Issue:** System experiencing ~70% iowait and 93% I/O pressure

## Problem Summary

System was experiencing severe I/O wait issues:
- **iowait:** ~67-70% (from `top` and `iostat`)
- **I/O pressure:** 93% sustained over 10sec/60sec/5min intervals
- **Blocked processes:** ~10 processes in D state (uninterruptible sleep)
- **Symptoms:** System very sluggish, applications freezing during I/O operations

## Investigation Findings

### System State at Time of Investigation
```
Memory: 32GB total
- Used: 20GB (applications)
- Slab: 12.8GB (mostly ZFS ARC)
- Available: 10.9GB

Swap: 24GB zvol on ZFS
- Used: 4.7GB
- Free: 19GB

Disk: 1TB NVMe (Samsung MZVL81T0HFLB)
- ZFS pool (rpool): 553GB used / 391GB free
- Single device, encrypted
```

### Root Cause Analysis

**Primary issue:** Memory pressure feedback loop
1. ZFS ARC consuming ~12.8GB of RAM (Slab memory)
2. Applications (Brave browser, Emacs, claude, etc.) using ~20GB
3. Total memory pressure forcing 4.7GB into swap
4. **Swap is on ZFS zvol** → creates feedback loop:
   - Swap I/O must go through ZFS
   - ZFS needs memory for I/O operations
   - More memory pressure → more swapping → more I/O wait
   - Result: 93% I/O pressure, processes constantly blocked

**Secondary factors:**
- Swap size (24GB) is excessive for a 32GB RAM system
- No way to move swap off ZFS without full repartition (entire disk allocated to ZFS)
- ZFS zvol swap has inherent overhead vs regular partition

### Key Diagnostic Commands Used

```bash
# I/O pressure (THE smoking gun - showed 93% pressure)
cat /proc/pressure/io

# Memory breakdown
free -h
cat /proc/meminfo | grep -E "(MemTotal|MemFree|Slab|Swap)"

# ZFS ARC stats
cat /proc/spl/kstat/zfs/arcstats | grep -E "^(size|c_max|hits|misses)"

# Blocked processes
vmstat 1 3  # Shows 'b' column with ~10 blocked processes
ps aux | awk '$8 ~ /D/ {print $0}'  # D-state processes

# I/O stats
iostat -x 1 3
zpool iostat -v 1 2
```

### What Didn't Work / Red Herrings

- **rclone FUSE mounts:** User confirmed high iowait existed before these were added
- **USB errors in logs:** Some over-current conditions but not the primary cause
- **Disk health:** NVMe is healthy, ZFS pool is healthy (no errors)
- **Moving swap off ZFS:** Would require full backup/repartition/restore (too risky)

## Implemented Solution

### Fix 1: Limit ZFS ARC Size
**File:** `hosts/anoa/default.nix`
**Change:** Added `boot.kernelParams = [ "zfs.zfs_arc_max=8589934592" ];`
**Effect:** Limits ZFS ARC to 8GB (down from ~13GB)
**Impact:** Frees ~5GB for applications, reduces memory pressure

### Fix 2: Reduce Swap Size
**File:** `hosts/anoa/disk.nix`
**Change:** Reduced swap zvol from `size = "24G"` to `size = "12G"`
**Effect:** Less swap available, but 12GB is still plenty for 32GB RAM
**Impact:** Reduces amount of data that can thrash on ZFS zvol

## Deployment Steps

1. Disable current swap: `sudo swapoff /dev/zvol/rpool/enc/swap`
2. Destroy old zvol: `sudo zfs destroy rpool/enc/swap`
3. Rebuild NixOS: `sudo nixos-rebuild switch --flake .#anoa --refresh`
4. Reboot to activate ZFS ARC kernel parameter

## Verification Commands

After reboot, verify the fixes:

```bash
# Check ZFS ARC is limited to 8GB
cat /proc/spl/kstat/zfs/arcstats | grep "^size"
# Expected: ~8589934592 bytes (8GB)

# Check swap size is 12GB
swapon --show
# Expected: 12GB total

# Monitor iowait (should be dramatically lower)
iostat -x 1 5
# Expected: wa% should be <20% instead of 70%

# Check I/O pressure
cat /proc/pressure/io
# Expected: avg10/avg60/avg300 should be <10% instead of 93%

# Check blocked processes
vmstat 1 5
# Expected: 'b' column should be 0-2 instead of 10
```

## Current Status

**Changes committed:** YES
**Changes deployed:** NO (pending rebuild)
**Next step:** User needs to disable swap, destroy zvol, rebuild NixOS, and reboot

## Additional Notes

### Why Swap on ZFS is Problematic
- ZFS uses memory for ARC (cache), metadata, and I/O operations
- When system swaps, it needs to do I/O through ZFS
- ZFS I/O requires memory allocation
- Under memory pressure: swap → ZFS I/O → needs memory → more swap → death spiral
- This is why the system showed 93% I/O pressure with processes constantly blocked

### System Configuration Details
- **Boot:** Secure Boot with lanzaboote (systemd-boot replacement)
- **Encryption:** ZFS native encryption (aes-256-gcm)
- **Impermanence:** Root filesystem wiped on every boot (rpool/enc/root@blank)
- **Persist:** /persist and /nix are persistent ZFS datasets
- **Snapshots:** zfs-auto-snap running (frequent/hourly/daily/weekly/monthly)

### If Issue Persists After Fix

If iowait is still high after applying both fixes:
1. Consider disabling swap entirely (test with `sudo swapoff -a`)
2. Check if specific applications are doing heavy I/O (use `iotop -o` with sudo)
3. Review browser tab count (Brave had many tabs open, using significant memory)
4. Consider increasing RAM if workload consistently needs >32GB

### Long-term Considerations

For best performance, swap should ideally be on a separate partition outside ZFS. However, this requires:
- Full system backup
- Destroy ZFS pool
- Repartition disk (e.g., 32GB swap partition + ZFS partition)
- Restore system

This is only worth doing during a full system rebuild/reinstall.
