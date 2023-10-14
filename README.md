# sifrOS: My Secure NixOS Configuration

## Hosts

- goral: A VM that runs on my M2 Macbook Air (current daily driver)
- serow: My ThinkPad T590
- tahr: My work-provided ThinkPad P1
- duisk: The server that runs huma.id

## Setup

1. Get NixOS 23.05 or newer.
2. Boot the image.
3. Define and format the partition, mount it on `/mnt`.
4. Install sifr:
    ```
    nix-shell -p git nixFlakes neovim
    git clone https://git.sr.ht/~humaid/sifr /tmp/sifr
    cd /tmp/sifr

    HOST=...

    # Get HW configuration
    nixos-generate-config --root /mnt --dir /tmp/nixconfig

    cp /tmp/nixconfig/hardware-configuration.nix ./hardware/${HOST}.nix
    nvim ./hardware/${HOST}.nix

    # Create host configuration (if doesn't exist), base from similar host
    cp ./hosts/serow.nix ./hosts/${HOST}.nix
    nvim ./hosts/${HOST}.nix

    # Add host to flake.nix
    nvim flake.nix

    nixos-install --flake .#${HOST}

    cp -r /tmp/sifr /mnt/etc/sifr
    ```

## TODOs

- Automated install script/image
- Raspberry Pi image
- Docker image
- Secret management
