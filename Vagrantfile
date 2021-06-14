# -*- mode: ruby -*-
# vi: set ft=ruby :

# To start, run
#
#   vagrant up <machine-name>
#
# where <machine-name> is one of buster64, win10, macOS
#
# To see a GUI, open the VirtualBox GUI and click on the running machine, then
# click the <Show> button.

Vagrant.configure("2") do |config|
  config.vm.define :buster64, autostart: false do |buster|
    buster.vm.box = "debian/contrib-buster64"
    buster.ssh.forward_x11 = true

    buster.vm.synced_folder ".", "/home/vagrant/orb/work"

    buster.vm.provision :shell, privileged: false, inline: <<~SHELL
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends xauth

    # Install app dependencies
    cd /home/vagrant/orb/work
    perl ./maint/helper.pl setup-cpan-client
    perl ./maint/helper.pl install-native-packages
    perl ./maint/helper.pl install-via-cpanfile
    SHELL

    buster.vm.post_up_message = <<~'MSG'
    If you have an X11 server on the host, you can use SSH X11 forwarding:

      [HOST] $ vagrant ssh buster64 -c 'cd /home/vagrant/orb/work && perl ./maint/helper.pl exec perl ./bin/app.pl'
    MSG
  end

  config.vm.define :win10, autostart: false do |win10|
    win10.vm.box = "StefanScherer/windows_10"

    win10.vm.synced_folder ".", "C:/vagrant" # SMB shared folder

    # WinRM support:
    # $ sudo gem install winrm winrm-elevated
    win10.vm.provision :shell, inline: <<~'PSH'
    # Install Chocolatey
    Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"; iwr https://chocolatey.org/install.ps1 -UseBasicParsing | iex

    # Install msys2 with Chocolatey
    $Env:MSYS2_DIR = 'msys64'
    $Env:MSYSTEM = 'MINGW64'
    choco install -y --allowemptychecksum msys2 --params " /InstallDir:C:/$Env:MSYS2_DIR"
    choco install -y --allowemptychecksum wixtoolset

    # Install toolchain and Perl inside of MSYS2-MinGW64
    $Env:PATH = "C:\$Env:MSYS2_DIR\$Env:MSYSTEM\bin;C:\$Env:MSYS2_DIR\usr\bin;$Env:PATH"
    bash -lc 'pacman -Syu'
    bash -lc 'pacman -S --needed --noconfirm base-devel mingw-w64-x86_64-toolchain mingw-w64-x86_64-perl'

    # Copy from shared (SMB) synced Vagrant folder into local directory.
    md C:\orb\work
    xcopy C:\vagrant C:\orb\work /s /e /h /y

    # Install app dependencies
    bash -lc 'cd /c/orb/work && perl ./maint/helper.pl setup-cpan-client'
    bash -lc 'cd /c/orb/work && perl ./maint/helper.pl install-native-packages'
    bash -lc 'cd /c/orb/work && perl ./maint/helper.pl install-via-cpanfile'
    PSH

    win10.vm.post_up_message = <<~'MSG'
    Run GUI and in C:\msys64\mingw64.exe:

      [GUEST-MINGW64] $ cd /c/orb/work && perl ./maint/helper.pl exec perl ./bin/app.pl
    MSG
  end

  ## The macOS box can be set up using
  ## <https://github.com/myspaghetti/macos-virtualbox>.
  ##
  ## Using steps:
  ##
  ##   $ ./macos-guest-virtualbox.sh
  ##
  ## Apply basebox settings
  ##   - <https://www.vagrantup.com/docs/virtualbox/boxes.html>
  ##   - <https://www.vagrantup.com/docs/boxes/base.html>
  ##
  ## which are:
  ##
  ##   - login: vagrant:vagrant
  ##
  ##   - Enable remote login:
  ##
  ##        Sharing -> Remote Login -> On
  ##
  ##   - Enable sudo for vagrant user
  ##
  ##       $ sudo visudo
  ##
  ##     and add to the end of the file
  ##
  ##       vagrant ALL=(ALL) NOPASSWD: ALL
  ##
  ##   - Disable reverse DNS for sshd:
  ##
  ##       $ sudo vi /etc/ssh/sshd_config
  ##
  ##     and edit to use
  ##
  ##       UseDNS No
  ##
  ##   - Install Vagrant authorized keys from
  ##
  ##       <https://github.com/hashicorp/vagrant/tree/master/keys>
  ##
  ##     and place in ~/.ssh/authorized_keys
  ##
  ##       $ mkdir ~/.ssh && chmod 0700 ~/.ssh
  ##       $ touch ~/.ssh/authorized_keys && chmod 0600 ~/.ssh/authorized_keys
  ##
  ##   - Install homebrew.
  ##
  ## Once the box is set up, create a Vagrant package:
  ##
  ##   $ vagrant package --base macOS-catalina
  ##   $ vagrant box add package.box --name macOS-catalina
  ##

  config.vm.define :macOS, autostart: false do |macOS|
    macOS.vm.box = "macOS-catalina"

    macOS.vm.synced_folder ".", "/Users/vagrant/orb/work", type: 'rsync',
      group: 'staff'
    macOS.vm.provision :shell, privileged: false, inline: <<~SHELL
    # Install Perl using Homebrew instead of using system Perl
    brew install perl

    # Install app dependencies
    cd /Users/vagrant/orb/work
    perl ./maint/helper.pl setup-cpan-client
    perl ./maint/helper.pl install-native-packages
    perl ./maint/helper.pl install-via-cpanfile
    SHELL

    macOS.vm.post_up_message = <<~'MSG'
    Run GUI and in Terminal:

      [GUEST-MACOS] $ cd /Users/vagrant/orb/work && perl ./maint/helper.pl exec perl ./bin/app.pl
    MSG

  end

  config.vm.provider "virtualbox" do |vb|
    # Display the VirtualBox GUI when booting the machine
    vb.gui = false

    # Customize the amount of memory on the VM:
    #vb.memory = "1024"
  end
end
