import pyautogui
import time
from datetime import datetime

button_images = ["image/run.png", "image/resume.png", "image/accept.png"]
SCALE_FACTOR = 0.5  # Scaling factor for display coordination correction
MOUSE_IDLE_THRESHOLD = 4  # Seconds to wait after mouse movement before clicking


def is_mouse_idle():
    """Check if mouse has been idle for the threshold time"""
    global last_mouse_pos, last_movement_time
    
    current_pos = pyautogui.position()
    current_time = time.time()
    
    # Initialize on first run
    if 'last_mouse_pos' not in globals():
        last_mouse_pos = current_pos
        last_movement_time = current_time
        return False
    
    # Check if mouse moved
    if current_pos != last_mouse_pos:
        last_mouse_pos = current_pos
        last_movement_time = current_time
        return False
    
    # Check if enough time has passed since last movement
    return (current_time - last_movement_time) >= MOUSE_IDLE_THRESHOLD

while True:
    for img in button_images:
        try:
            location = pyautogui.locateOnScreen(img, confidence=0.85)
            if location:
                center_point = pyautogui.center(location)
                # Apply scaling correction for multi-display setup
                corrected_x = int(center_point.x * SCALE_FACTOR)
                corrected_y = int(center_point.y * SCALE_FACTOR)
                
                # Only click if mouse has been idle
                if is_mouse_idle():
                    pyautogui.click(corrected_x, corrected_y)
                    print(f"[{datetime.now().strftime('%H:%M:%S')}] Clicked {img} at ({corrected_x}, {corrected_y})")
                break
        except pyautogui.ImageNotFoundException:
            # Image not found, continue searching
            pass
    time.sleep(1)

