_: {
  config = {
    topology.nodes.epson = {
      deviceType = "device";
      hardware.info = "Epson L4150 Printer";
      interfaces.wlan = {
        network = "home";
        addresses = [
          "epson.alq.ae"
          "192.168.1.52"
        ];
      };
    };
    topology.nodes.gertruda = {
      deviceType = "device";
      hardware.info = "Prusa MK3S+ 3D Printer (+ RPi3B)";
      interfaces.wlan = {
        network = "home";
        addresses = [
          "gertruda.alq.ae"
          "192.168.1.40"
        ];
      };
    };
  };
}
