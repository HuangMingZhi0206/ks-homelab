// Room hub — Arduino side.
//
// Reads the five buttons on a DFRobot-style LCD Keypad Shield, shows what was
// pressed, and tells the Raspberry Pi over USB serial. The Pi can write back
// to the screen, so an action started here can report its own result there.
//
// Protocol, line-based, newline-terminated in both directions:
//   Arduino -> Pi   BTN:SELECT
//   Pi -> Arduino   LCD:Homelab|CPU 47.2 C      (| splits the two rows)
//                   BL:0                        (backlight off)
//
// Nothing here blocks. delay() would mean a button press is missed while the
// screen is busy and a serial line arrives half-read — on a board with one
// thread, every delay is time the rest of the system does not exist.

#include <LiquidCrystal.h>

// Fixed by the shield's wiring, not a choice.
LiquidCrystal lcd(8, 9, 4, 5, 6, 7);
const uint8_t PIN_KEYS = A0;
const uint8_t PIN_BACKLIGHT = 10;

enum Button : uint8_t {
  BTN_NONE = 0, BTN_RIGHT, BTN_UP, BTN_DOWN, BTN_LEFT, BTN_SELECT
};

const char *BUTTON_NAME[] = {"NONE", "RIGHT", "UP", "DOWN", "LEFT", "SELECT"};

// The shield puts all five buttons on one analog pin through a resistor
// ladder, so each button is a voltage. Nominal readings on a 5 V board are
// 0 / 99 / 255 / 408 / 639, and 1023 with nothing pressed.
//
// The thresholds sit midway between neighbours rather than near the nominal
// values: supply voltage sags, resistor tolerance and a long USB cable all
// shift the readings, and midpoints keep the widest margin on both sides.
Button readRawButton() {
  const int v = analogRead(PIN_KEYS);
  if (v < 50)  return BTN_RIGHT;
  if (v < 195) return BTN_UP;
  if (v < 380) return BTN_DOWN;
  if (v < 555) return BTN_LEFT;
  if (v < 790) return BTN_SELECT;
  return BTN_NONE;
}

// Debounce by stability, not by waiting: a reading has to hold the same value
// for DEBOUNCE_MS before it counts. Contacts bounce for a few milliseconds,
// and the ladder also passes through neighbouring voltages while a button
// travels — so a single sample can report LEFT on the way to SELECT.
const unsigned long DEBOUNCE_MS = 30;

Button stableButton = BTN_NONE;   // what we currently believe is pressed
Button candidate = BTN_NONE;      // what the pin has been reading lately
unsigned long candidateSince = 0;

// Returns a button only on the transition from not-pressed to pressed, so
// holding a key sends one message rather than fifty a second.
Button pollButtonPress() {
  const Button now = readRawButton();
  const unsigned long t = millis();

  if (now != candidate) {
    candidate = now;
    candidateSince = t;
    return BTN_NONE;
  }

  if (t - candidateSince < DEBOUNCE_MS) return BTN_NONE;
  if (candidate == stableButton) return BTN_NONE;

  const Button previous = stableButton;
  stableButton = candidate;
  return (previous == BTN_NONE && stableButton != BTN_NONE) ? stableButton : BTN_NONE;
}

// --- screen ------------------------------------------------------------------

// The LCD keeps whatever was written until something overwrites it, so a
// shorter line leaves the tail of the previous one behind. Pad to 16.
void writeRow(uint8_t row, const char *text) {
  lcd.setCursor(0, row);
  uint8_t i = 0;
  for (; i < 16 && text[i]; i++) lcd.write(text[i]);
  for (; i < 16; i++) lcd.write(' ');
}

void showTwoRows(const char *top, const char *bottom) {
  writeRow(0, top);
  writeRow(1, bottom);
}

// --- serial in ---------------------------------------------------------------

// Read whatever bytes have arrived and return early. Serial.readStringUntil()
// would wait for the newline — a stall of up to a second on a line that may
// never be finished.
char rxBuf[48];
uint8_t rxLen = 0;

void handleLine(char *line) {
  if (strncmp(line, "LCD:", 4) == 0) {
    char *body = line + 4;
    char *split = strchr(body, '|');
    if (split) {
      *split = '\0';
      showTwoRows(body, split + 1);
    } else {
      showTwoRows(body, "");
    }
  } else if (strncmp(line, "BL:", 3) == 0) {
    digitalWrite(PIN_BACKLIGHT, line[3] == '0' ? LOW : HIGH);
  }
}

void pumpSerial() {
  while (Serial.available()) {
    const char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (rxLen) {
        rxBuf[rxLen] = '\0';
        handleLine(rxBuf);
        rxLen = 0;
      }
    } else if (rxLen < sizeof(rxBuf) - 1) {
      rxBuf[rxLen++] = c;
    } else {
      // Oversized line: drop it rather than overflow. Losing one message is
      // better than corrupting memory the rest of the sketch is using.
      rxLen = 0;
    }
  }
}

// --- main --------------------------------------------------------------------

void setup() {
  pinMode(PIN_BACKLIGHT, OUTPUT);
  digitalWrite(PIN_BACKLIGHT, HIGH);
  lcd.begin(16, 2);
  Serial.begin(115200);
  showTwoRows("Menu Homelab", "siap");

  // Announce ourselves: opening the port resets this board, so the Pi needs a
  // way to know the link is live again without guessing at a timeout.
  Serial.println(F("HELLO:roomhub"));
}

void loop() {
  pumpSerial();

  const Button pressed = pollButtonPress();
  if (pressed != BTN_NONE) {
    char row[17];
    snprintf(row, sizeof(row), "Tombol: %s", BUTTON_NAME[pressed]);
    showTwoRows("Menu Homelab", row);

    Serial.print(F("BTN:"));
    Serial.println(BUTTON_NAME[pressed]);
  }
}
