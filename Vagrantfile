# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.define :buster64, autostart: false do |buster|
    buster.vm.box = "debian/contrib-buster64"
  end

  config.vm.define :win10, autostart: false do |win10|
    win10.vm.box = "StefanScherer/windows_10"

    # WinRM support:
    # $ sudo gem install winrm winrm-elevated
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
  ## Optional:
  ##
  ##   - Install homebrew.
  ##   - Install sshfs
  ##
  ##       $ brew install Caskroom/cask/osxfuse
  ##       $ brew install sshfs
  ##       $ sshfs localhost:
  ##
  ##     then allow the extension to run
  ##
  ##       System Preferences -> Security & Privacy (General) -> Allow extension
  ##
  ## Once the box is set up, create a Vagrant package:
  ##
  ##   $ vagrant package --base macOS-catalina
  ##   $ vagrant box add package.box --name macOS-catalina
  ##

  #config.vm.define :macOS, autostart: false do |macOS|
    #macOS.vm.box = "macOS-catalina"
  #end

  config.vm.provider "virtualbox" do |vb|
    # Display the VirtualBox GUI when booting the machine
    vb.gui = false

    # Customize the amount of memory on the VM:
    vb.memory = "1024"
  end
end
