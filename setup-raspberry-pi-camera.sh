#!/bin/bash
#
# Raspberry Pi Camera Setup Script
# ================================
# 
# This script automates the setup of a Raspberry Pi camera and all required
# libraries for object detection with YOLOv8.
#
# Author: aoubd (xaoubd@gmail.com)
# 
# Usage:
#   chmod +x setup-raspberry-pi-camera.sh
#   ./setup-raspberry-pi-camera.sh

# Terminal colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print section headers
print_section() {
    echo -e "\n${BLUE}===================================================================${NC}"
    echo -e "${BLUE}🛠️  $1${NC}"
    echo -e "${BLUE}===================================================================${NC}"
}

# Function to check command success
check_success() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ $1${NC}"
    else
        echo -e "${RED}❌ $1${NC}"
        if [ "$2" = "exit" ]; then
            exit 1
        fi
    fi
}

# Function to check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}❌ This script must be run as root (using sudo)${NC}"
        echo -e "Please run the script using: ${YELLOW}sudo $0${NC}"
        exit 1
    fi
}

# Check if script is run with sudo
check_root

# Check Raspberry Pi model
print_section "Checking Raspberry Pi Model"
PI_MODEL=$(cat /proc/cpuinfo | grep Model)
echo "Device model: $PI_MODEL"

# Check OS version
OS_VERSION=$(cat /etc/os-release | grep "PRETTY_NAME" | cut -d'"' -f2)
echo "Operating system: $OS_VERSION"

# Update system packages
print_section "Updating System"
apt-get update
check_success "Package lists updated"
apt-get upgrade -y
check_success "System updated"

# Install required packages
print_section "Installing Required Packages"
apt-get install -y python3-pip python3-venv python3-dev
check_success "Basic Python packages installed"

# Install camera libraries
print_section "Installing Camera Libraries"
apt-get install -y libcamera-apps python3-picamera2 libcamera-dev python3-libcamera
check_success "libcamera libraries installed"

apt-get install -y libraspberrypi-bin libraspberrypi-dev v4l-utils fswebcam i2c-tools
check_success "Additional camera tools installed"

# Enable camera and i2c interfaces
print_section "Enabling Camera Interfaces"
raspi-config nonint do_camera 0
check_success "Camera interface enabled"
raspi-config nonint do_i2c 0
check_success "I2C interface enabled"

# Fix camera permissions
print_section "Setting Camera Permissions"
# Add current user to video group
USER=$(logname)
usermod -a -G video $USER
check_success "User $USER added to video group"

# Make video devices accessible
chmod 666 /dev/video* 2>/dev/null
check_success "Video device permissions set"

# Load camera modules
print_section "Loading Camera Modules"
modprobe bcm2835-v4l2
check_success "bcm2835-v4l2 module loaded"
modprobe v4l2_common
modprobe videodev
check_success "Additional video modules loaded"

# Check if camera is detected
print_section "Checking Camera"
if ls /dev/video* &>/dev/null; then
    echo -e "${GREEN}✅ Video devices found:${NC}"
    ls -l /dev/video*
else
    echo -e "${YELLOW}⚠️ No video devices found. Make sure the camera is properly connected.${NC}"
fi

# Display camera info
echo -e "\n${BLUE}Detailed camera information:${NC}"
v4l2-ctl --list-devices

# Create virtual environment for YOLOv8
print_section "Setting up YOLOv8 Environment"
YOLO_ENV_DIR="/home/$USER/yolo_env"
YOLO_MODEL_DIR="/home/$USER/yolo_models"

# Create directories
mkdir -p $YOLO_MODEL_DIR
chown $USER:$USER $YOLO_MODEL_DIR

# Create virtual environment
if [ ! -d "$YOLO_ENV_DIR" ]; then
    su - $USER -c "python3 -m venv $YOLO_ENV_DIR"
    check_success "Virtual environment created"
else
    echo -e "${YELLOW}⚠️ Virtual environment already exists${NC}"
fi

# Install YOLOv8 requirements
su - $USER -c "$YOLO_ENV_DIR/bin/pip install --upgrade pip"
su - $USER -c "$YOLO_ENV_DIR/bin/pip install ultralytics opencv-python"
check_success "YOLOv8 core libraries installed"

# Install camera libraries in virtual environment
su - $USER -c "$YOLO_ENV_DIR/bin/pip install picamera2"
check_success "picamera2 installed in virtual environment"

# Download YOLOv8 model
print_section "Downloading YOLOv8 Model"
YOLO_MODEL="$YOLO_MODEL_DIR/yolov8n.pt"
if [ ! -f "$YOLO_MODEL" ]; then
    su - $USER -c "wget -O $YOLO_MODEL https://github.com/ultralytics/assets/releases/download/v0.0.0/yolov8n.pt"
    check_success "YOLOv8n model downloaded"
else
    echo -e "${YELLOW}⚠️ YOLOv8n model already exists${NC}"
fi

# Create a test script for camera capture
print_section "Creating Camera Test Script"
CAPTURE_SCRIPT="/home/$USER/capture_image.py"

cat > $CAPTURE_SCRIPT << 'EOF'
#!/usr/bin/env python3
import sys
import time
import os
import subprocess
import datetime

# Set up logging
def log(message):
    timestamp = datetime.datetime.now().strftime('%H:%M:%S')
    print(f"[{timestamp}] {message}")

log("Starting camera capture script...")

def capture_with_libcamera():
    """Capture image using libcamera-still command line tool (recommended for Pi 5)"""
    try:
        log("Attempting to use libcamera-still...")
        path = "captured.jpg"
        
        # Remove existing image if it exists
        if os.path.exists(path):
            os.remove(path)
            
        # Run libcamera-still with a 2-second timeout
        cmd = ["libcamera-still", "-t", "2000", "-o", path]
        log(f"Running command: {' '.join(cmd)}")
        
        process = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        
        if process.returncode != 0:
            log(f"libcamera-still failed with return code {process.returncode}")
            if process.stderr:
                log(f"Error output: {process.stderr}")
            return False
            
        # Verify image was saved
        if os.path.exists(path) and os.path.getsize(path) > 0:
            log(f"Successfully saved image ({os.path.getsize(path)} bytes)")
            return True
        else:
            log("Image capture failed or file is empty")
            return False
            
    except subprocess.TimeoutExpired:
        log("libcamera-still process timed out")
        return False
    except Exception as e:
        log(f"Error with libcamera-still: {e}")
        return False

def capture_with_picamera2():
    """Capture image using picamera2 Python module"""
    try:
        log("Attempting to use Picamera2...")
        from picamera2 import Picamera2
        
        # Initialize camera
        picam2 = Picamera2()
        preview_config = picam2.create_preview_configuration()
        picam2.configure(preview_config)
        picam2.start()
        
        # Add a delay to allow camera to adjust
        log("Camera warming up...")
        time.sleep(2)
        
        # Capture image
        path = "captured.jpg"
        log(f"Capturing image to {path}...")
        picam2.capture_file(path)
        picam2.stop()
        
        # Verify image was saved
        if os.path.exists(path) and os.path.getsize(path) > 0:
            log(f"Successfully saved image ({os.path.getsize(path)} bytes)")
            return True
        else:
            log("Image capture failed or file is empty")
            return False
    
    except Exception as e:
        log(f"Error with Picamera2: {e}")
        return False

def capture_with_opencv():
    """Capture image using OpenCV"""
    try:
        log("Attempting to use OpenCV...")
        import cv2
        
        # Try different camera indices
        for camera_index in range(3):  # Try camera 0, 1, and 2
            log(f"Trying camera index {camera_index}...")
            cap = cv2.VideoCapture(camera_index)
            
            if not cap.isOpened():
                log(f"Could not open camera {camera_index}")
                continue
            
            # Try setting some properties to ensure camera is properly initialized
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            
            # Try multiple reads as sometimes the first frame fails
            success = False
            for attempt in range(5):
                log(f"Read attempt {attempt+1}...")
                # Read a frame
                ret, frame = cap.read()
                if ret:
                    success = True
                    break
                time.sleep(0.5)
            
            if not success:
                log(f"Could not read from camera {camera_index} after multiple attempts")
                cap.release()
                continue
                
            # Save the frame
            path = "captured.jpg"
            log(f"Capturing image to {path}...")
            result = cv2.imwrite(path, frame)
            cap.release()
            
            if result and os.path.exists(path) and os.path.getsize(path) > 0:
                log(f"Successfully saved image ({os.path.getsize(path)} bytes) using camera {camera_index}")
                return True
        
        log("All camera indices failed")
        return False
    
    except Exception as e:
        log(f"Error with OpenCV: {e}")
        return False

# Try each method in order until one succeeds - starting with libcamera-still which works best on Pi 5
methods = [
    ("libcamera-still", capture_with_libcamera),
    ("Picamera2", capture_with_picamera2),
    ("OpenCV", capture_with_opencv)
]

success = False
for method_name, method_func in methods:
    log(f"Trying {method_name} method...")
    if method_func():
        log(f"✅ {method_name} method successful!")
        success = True
        break
    else:
        log(f"❌ {method_name} method failed.")

if not success:
    log("❌ All camera methods failed. Please check camera connection and permissions.")
    sys.exit(1)
else:
    log("✅ Image capture completed successfully!")
    sys.exit(0)
EOF

# Make script executable and set ownership
chmod +x $CAPTURE_SCRIPT
chown $USER:$USER $CAPTURE_SCRIPT
check_success "Camera test script created"

# Create a YOLO object detection script
print_section "Creating Person Detection Script with YOLO"
DETECTION_SCRIPT="/home/$USER/detect_person_yolo.py"

cat > $DETECTION_SCRIPT << 'EOF'
#!/usr/bin/env python3
# Person detection using YOLOv8
# Author: aoubd (xaoubd@gmail.com)

import os
import sys
import time
import subprocess
from datetime import datetime
from ultralytics import YOLO

# Configuration
MODEL_PATH = "yolov8n.pt"  # Path to the YOLOv8 model
IMAGE_PATH = "captured.jpg"  # Path to the captured image
RESULT_PATH = "result.jpg"   # Path to save the detection result
CONFIDENCE = 0.25            # Detection confidence threshold
CLASSES = [0]                # Class IDs to detect (0 = person)

def log(message):
    """Print a timestamped log message."""
    timestamp = datetime.now().strftime('%H:%M:%S')
    print(f"[{timestamp}] {message}")

def capture_image():
    """Capture an image using libcamera-still."""
    log("Capturing image...")
    
    # Remove existing image if it exists
    if os.path.exists(IMAGE_PATH):
        os.remove(IMAGE_PATH)
    
    # Try to capture with libcamera-still
    try:
        result = subprocess.run(
            ["libcamera-still", "-t", "2000", "-o", IMAGE_PATH],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode != 0:
            log(f"Error capturing image: {result.stderr}")
            return False
            
        # Check if image exists and is not empty
        if os.path.exists(IMAGE_PATH) and os.path.getsize(IMAGE_PATH) > 0:
            log(f"Image captured successfully ({os.path.getsize(IMAGE_PATH)} bytes)")
            return True
        else:
            log("Image capture failed or file is empty")
            return False
    except Exception as e:
        log(f"Error capturing image: {e}")
        # Try OpenCV as fallback
        return capture_with_opencv()

def capture_with_opencv():
    """Capture an image using OpenCV as a fallback method."""
    log("Attempting to capture with OpenCV...")
    try:
        import cv2
        
        # Try camera device 0
        cap = cv2.VideoCapture(0)
        if not cap.isOpened():
            log("Could not open camera")
            return False
        
        # Read a frame
        ret, frame = cap.read()
        cap.release()
        
        if not ret:
            log("Could not read frame from camera")
            return False
        
        # Save the frame
        result = cv2.imwrite(IMAGE_PATH, frame)
        
        if result and os.path.exists(IMAGE_PATH) and os.path.getsize(IMAGE_PATH) > 0:
            log(f"OpenCV image capture successful ({os.path.getsize(IMAGE_PATH)} bytes)")
            return True
        else:
            log("OpenCV image capture failed")
            return False
    except Exception as e:
        log(f"Error with OpenCV: {e}")
        return False

def detect_persons():
    """Detect persons in the captured image using YOLOv8."""
    if not os.path.exists(IMAGE_PATH):
        log(f"Image not found: {IMAGE_PATH}")
        return False, 0
    
    log("Loading YOLO model...")
    try:
        # Load the model
        model = YOLO(MODEL_PATH)
        
        # Run detection
        log("Running detection...")
        results = model(IMAGE_PATH, conf=CONFIDENCE, classes=CLASSES)
        
        # Save results
        log("Saving detection results...")
        res_plotted = results[0].plot()
        
        import cv2
        cv2.imwrite(RESULT_PATH, res_plotted)
        
        # Count detected persons
        detections = results[0].boxes.data
        num_persons = len(detections)
        
        log(f"Detection complete. Found {num_persons} persons.")
        return True, num_persons
    except Exception as e:
        log(f"Error during detection: {e}")
        return False, 0

def main():
    """Main function to run the detection pipeline."""
    log("Starting person detection...")
    
    # Step 1: Capture an image
    if not capture_image():
        log("Failed to capture image. Exiting.")
        return 1
    
    # Step 2: Detect persons in the image
    success, num_persons = detect_persons()
    if not success:
        log("Failed to run detection. Exiting.")
        return 1
    
    # Step 3: Report results
    if num_persons > 0:
        log(f"✅ Detected {num_persons} persons in the image.")
        log(f"Result saved as {RESULT_PATH}")
    else:
        log("❌ No persons detected in the image.")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
EOF

# Make script executable and set ownership
chmod +x $DETECTION_SCRIPT
chown $USER:$USER $DETECTION_SCRIPT
check_success "YOLO person detection script created"

# Test camera
print_section "Testing Camera"
echo -e "${YELLOW}Testing camera now... ${NC}"

# Try to capture a test image
TEST_IMAGE="/tmp/test_camera.jpg"
rm -f $TEST_IMAGE 2>/dev/null

if libcamera-still -t 2000 -o $TEST_IMAGE; then
    if [ -f "$TEST_IMAGE" ]; then
        echo -e "${GREEN}✅ Test image captured successfully using libcamera-still.${NC}"
        echo -e "   Image saved at: $TEST_IMAGE"
    else
        echo -e "${RED}❌ Failed to create image file.${NC}"
    fi
else
    echo -e "${RED}❌ Failed to capture test image using libcamera-still.${NC}"
    echo -e "${YELLOW}⚠️ Trying alternative method using fswebcam...${NC}"
    
    if fswebcam -r 640x480 --no-banner $TEST_IMAGE; then
        if [ -f "$TEST_IMAGE" ]; then
            echo -e "${GREEN}✅ Test image captured successfully using fswebcam.${NC}"
            echo -e "   Image saved at: $TEST_IMAGE"
        else
            echo -e "${RED}❌ Failed to create image file using fswebcam.${NC}"
        fi
    else
        echo -e "${RED}❌ Failed to capture test image using fswebcam.${NC}"
    fi
fi

# Final instructions
print_section "Installation Complete"
echo -e "${GREEN}✅ Raspberry Pi Camera and YOLOv8 libraries setup complete!${NC}"
echo -e "\n${BLUE}To verify camera setup, run:${NC}"
echo -e "   ${YELLOW}cd /home/$USER${NC}"
echo -e "   ${YELLOW}source yolo_env/bin/activate${NC}"
echo -e "   ${YELLOW}python capture_image.py${NC}"
echo -e "\n${BLUE}To run person detection using YOLO:${NC}"
echo -e "   ${YELLOW}cd /home/$USER${NC}"
echo -e "   ${YELLOW}source yolo_env/bin/activate${NC}"
echo -e "   ${YELLOW}python detect_person_yolo.py${NC}"
echo -e "\n${BLUE}Created files:${NC}"
echo -e "   - Python virtual environment: ${YELLOW}$YOLO_ENV_DIR${NC}"
echo -e "   - YOLO models folder: ${YELLOW}$YOLO_MODEL_DIR${NC}"
echo -e "   - Image capture script: ${YELLOW}$CAPTURE_SCRIPT${NC}"
echo -e "   - Person detection script: ${YELLOW}$DETECTION_SCRIPT${NC}"

# Recommend a reboot
echo -e "\n${YELLOW}⚠️ To ensure all changes take effect, a system reboot is recommended.${NC}"
echo -e "   To reboot now, type: ${YELLOW}sudo reboot${NC}"

echo -e "\n${BLUE}Author: aoubd (xaoubd@gmail.com)${NC}"
exit 0
