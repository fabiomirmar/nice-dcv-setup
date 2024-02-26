#!/bin/bash

# Upgrade all packages
sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y

# Install desktop
sudo DEBIAN_FRONTEND=noninteractive apt install ubuntu-desktop gdm3 -y

# Configure GDM to use Xorg
sudo sed -i 's/\#WaylandEnable\=false/WaylandEnable\=false/' /etc/gdm3/custom.conf
sudo systemctl restart gdm3
sudo systemctl set-default graphical.target
sudo systemctl isolate graphical.target

sleep 30
ps aux | grep X | grep -v grep
XORG_RUN=$(echo $?)

if [ "$XORG_RUN" -eq "0" ]; then
	echo "Xorg running. Continuing set up."
else
	echo "Xorg not running. Exiting."
	exit 1
fi

# Install additional packages
sudo DEBIAN_FRONTEND=noninteractive apt install mesa-utils -y
sudo DISPLAY=:0 XAUTHORITY=$(ps aux | grep "X.*\-auth" | grep -v grep | sed -n 's/.*-auth \([^ ]\+\).*/\1/p') glxinfo | grep -i "opengl.*version"
OPENGLREND=$(echo $?)
if [ "$OPENGLREND" -eq "0" ]; then
	echo "OpenGL Rendering is available. Continuing set up."
else
	echo "Xorg not running. Exiting."
	exit 1
fi


# Prepare for Nvidia driver installation
sudo DEBIAN_FRONTEND=noninteractive apt install -y gcc make linux-headers-$(uname -r)

cat << EOF | sudo tee --append /etc/modprobe.d/blacklist.conf
blacklist vga16fb
blacklist nouveau
blacklist rivafb
blacklist nvidiafb
blacklist rivatv
EOF

sudo sed -i 's/GRUB_CMDLINE_LINUX\=/\#GRUB_CMDLINE_LINUX\=/' /etc/default/grub
GRUBOPTS=$(grep -w GRUB_CMDLINE_LINUX /etc/default/grub | cut -d = -f 2 | cut -d \" -f 2 | sed 's/$/ rdblacklist=nouveau/')
sudo sed -i "/#GRUB_CMDLINE_LINUX=/a GRUB_CMDLINE_LINUX=\"$GRUBOPTS\"" /etc/default/grub
sudo update-grub

# Requires assigning a IAM role to allow your instances to use s3 service
# Download NVidia drivers and install
sudo snap install aws-cli --channel=v2/stable --classic
aws s3 cp --recursive s3://ec2-linux-nvidia-drivers/latest/ .
chmod +x NVIDIA-Linux-x86_64*.run
sudo DEBIAN_FRONTEND=noninteractive apt install libglvnd-dev pkg-config -y
NVIDIA_SCRIPT=$(ls ./NVIDIA-Linux-x86_64*)
sudo /bin/sh $NVIDIA_SCRIPT -a -q --dkms

nvidia-smi -q | head
NVIDIAWORK=$(echo $?)
if [ "$NVIDIAWORK" -eq "0" ]; then
	echo "Nvidia driver working. Continuing set up."
else
	echo "Nvidia driver not running. Exiting."
	exit 1
fi

# Configure Xorg to use Nvidia
sudo nvidia-xconfig --preserve-busid --enable-all-gpus --connected-monitor=DFP-0,DFP-1,DFP-2,DFP-3

sudo systemctl isolate multi-user.target
sudo systemctl isolate graphical.target
sleep 30

ps aux | grep X | grep -v grep
XORG_RUN=$(echo $?)

if [ "$XORG_RUN" -eq "0" ]; then
	echo "Xorg running. Continuing set up."
else
	echo "Xorg not running. Exiting."
	exit 1
fi

# Download and install DCV
wget https://d1uj6qtbmh3dt5.cloudfront.net/NICE-GPG-KEY
gpg --import NICE-GPG-KEY

UBUNTUVER=$(lsb_release -r -s | sed 's/\.//')

wget "https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-ubuntu$UBUNTUVER-x86_64.tgz"

DIRECTORY=$(tar tf nice-dcv-ubuntu2204-x86_64.tgz | head -1)
tar xvf nice-dcv-ubuntu2204-x86_64.tgz
cd $DIRECTORY

sudo DEBIAN_FRONTEND=noninteractive apt install ./$(ls nice-dcv-server*) ./$(ls nice-dcv-web-viewer*) ./$(ls nice-xdcv*) ./$(ls nice-dcv-gltest*) ./$(ls nice-dcv-gl_*) -y

sudo usermod -aG video dcv

# Install additioanl packages for DCV
sudo DEBIAN_FRONTEND=noninteractive apt install dkms pulseaudio-utils -y
sudo dcvusbdriverinstaller --quiet

# Finalize DCV set up
sudo systemctl isolate multi-user.target
sudo dcvgladmin disable
sudo dcvgladmin enable
sudo systemctl isolate graphical.target
sleep 30
ps aux | grep X | grep -v grep
XORG_RUN=$(echo $?)

if [ "$XORG_RUN" -eq "0" ]; then
	echo "Xorg running. Continuing set up."
else
	echo "Xorg not running. Exiting."
	exit 1
fi

echo "Check if local users can access X server. Command should return 'SI:localuser:dcv'"
sudo DISPLAY=:0 XAUTHORITY=$(ps aux | grep "X.*\-auth" | grep -v grep | sed -n 's/.*-auth \([^ ]\+\).*/\1/p') xhost | grep "SI:localuser:dcv$"

echo "Check if local users can access X server. Command should return 'LOCAL:'"
sudo DISPLAY=:0 XAUTHORITY=$(ps aux | grep "X.*\-auth" | grep -v grep | sed -n 's/.*-auth \([^ ]\+\).*/\1/p') xhost | grep "LOCAL:$"

# Configure DCV sessions
sudo sed -i 's/#create-session = true/create-session = true/' /etc/dcv/dcv.conf
sudo sed -i 's/#owner = ""/owner = "ubuntu"/' /etc/dcv/dcv.conf

sudo systemctl enable dcvserver.service
sudo systemctl start dcvserver.service
dcv list-sessions

# Set a ubuntu password so we can login
echo "ubuntu:passw0rd" | sudo chpasswd

# Configure a divert to use Xdcv instead of Xorg
sudo mv /usr/bin/Xorg /usr/bin/Xorg.orig
cat | sudo tee /usr/bin/Xdcv-console  <<EOF
#!/bin/sh
exec /usr/bin/Xdcv -output 800x600+0+0 -output 800x600+800+0 -output 800x600+1600+0 -output 800x600+2400+0 -enabledoutputs 1 "\$@"
EOF

sudo chmod +x /usr/bin/Xdcv-console
sudo ln -sf /usr/bin/Xdcv-console /usr/bin/Xorg

sudo systemctl isolate multi-user.target
sudo systemctl isolate graphical.target
sleep 30
ps aux | grep X | grep -v grep
XDCV_RUN=$(echo $?)

if [ "$XDCV_RUN" -eq "0" ]; then
	echo "Xdcv running. Continuing set up."
else
	echo "Xdcv not running. Exiting."
	exit 1
fi

