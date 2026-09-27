/*
 * ============================================================
 *  SMART ROOM IR REMOTE v10 - LCD Keypad Shield
 *
 *  FITUR
 *    - Lampu Meja  : 6 perintah (NEC, data raw hasil rekaman)
 *    - AC Panasonic: kontrol PENUH berbasis state
 *                    (power, suhu 16-30C, kecepatan kipas)
 *                    frame dibangun di kode, bukan rekaman
 *    - Sensor DHT11: suhu & kelembapan ruangan
 *    - Jam         : tampil di HOME, bisa disinkron dari Raspberry Pi
 *    - Serial      : lapor status & terima perintah dari Raspberry Pi
 *
 *  WIRING
 *    IR LED     : D3
 *    DHT11 DATA : D2
 *    LCD Shield : D4-D10, A0 (bawaan shield)
 *    Raspberry Pi:
 *        Arduino TX (D1) --[1k]--+--> Pi RXD (GPIO15)
 *                                |
 *                              [2k]
 *                                |
 *                               GND     <- WAJIB, Pi hanya tahan 3.3V
 *        Arduino RX (D0) <----------- Pi TXD (GPIO14)
 *        GND <-> GND
 *      Cabut D0/D1 saat upload sketch.
 *
 *      CATATAN: di homelab ini papan disambung lewat USB, bukan GPIO UART.
 *      D0/D1 dipakai bersama oleh chip USB, jadi JANGAN pasang pembagi
 *      tegangan di atas sekaligus dengan kabel USB -- dua pengirim di satu
 *      jalur hanya menghasilkan sampah. Pilih salah satu. Lihat roomhub/README.
 *
 *  KONTROL
 *    HOME    : SELECT/RIGHT = buka menu
 *    KATEGORI: UP/DOWN geser | RIGHT masuk | LEFT ke HOME
 *    PERINTAH: UP/DOWN geser | SELECT jalankan | LEFT kembali
 *    SET JAM : UP/DOWN ubah | RIGHT pindah kolom | SELECT simpan
 *
 *  PETA BIT AC PANASONIC (dibaca dari remote asli, terverifikasi)
 *    byte5  : mode (nibble atas, 3 = dingin) + power (bit 0)
 *    byte6  : suhu x 2            (25C -> 0x32)
 *    byte8  : kipas (nibble atas: A=auto, 3=pelan .. 7=kencang)
 *             swing (nibble bawah)
 *    byte18 : checksum = jumlah byte 0..17, ambil 8 bit bawah
 *
 *  CATATAN: Arduino tidak tahu kondisi AC yang sebenarnya. Kalau kamu
 *  juga memakai remote asli, state di Arduino bisa ketinggalan. Tekan
 *  perintah AC apa saja dari menu, dan AC akan menyamakan diri lagi.
 *
 *  LIBRARY
 *    - IRremote (v4.x)
 *    - DHT sensor library (Adafruit) + Adafruit Unified Sensor
 * ============================================================
 */

#include <Arduino.h>

// ============================================================
//  PENTING - HARUS SEBELUM #include <IRremote.hpp>
//
//  Tanpa ini, gelombang pembawa 38kHz dibangkitkan oleh SOFTWARE:
//  CPU menyalakan/mematikan pin ribuan kali per detik sambil
//  menghitung waktu manual. Interupsi lain (Serial, millis) menyela
//  proses itu dan timing jadi meleset -> IR kadang jalan kadang tidak.
//
//  Dengan SEND_PWM_BY_TIMER, carrier dibangkitkan HARDWARE TIMER2.
//  Timer bekerja sendiri di level chip, kebal terhadap interupsi.
//
//  KONSEKUENSI: pin pengirim TERKUNCI di D3 (jalur OC2B Timer2).
//  Kebetulan LED IR kita memang sudah di D3, jadi tidak perlu diubah.
//  Timer2 juga dipakai fungsi tone() - jangan pakai tone() di sketch ini.
// ============================================================
#define SEND_PWM_BY_TIMER

#include <IRremote.hpp>
#include <LiquidCrystal.h>
#include <DHT.h>

// ---------- Pin ----------
#define IR_SEND_PIN 3
#define DHT_PIN     2
#define DHT_TIPE    DHT11
#define BUTTON_PIN  A0

LiquidCrystal lcd(8, 9, 4, 5, 6, 7);
DHT dht(DHT_PIN, DHT_TIPE);

// ============================================================
//  ENUM - WAJIB di atas semua fungsi.
//  Arduino IDE otomatis menyisipkan prototipe fungsi di bagian atas
//  file. Kalau enum didefinisikan setelah fungsi pertama, prototipe
//  seperti "Tombol bacaTombol();" akan muncul sebelum tipe Tombol
//  dikenal -> error "does not name a type".
// ============================================================
enum Tombol { NONE, RIGHT, UP, DOWN, LEFT, SELECT };
enum Layar  { HOME, PILIH_KATEGORI, PILIH_PERINTAH, SET_JAM };
enum AksiAC { AC_POWER, AC_SUHU_NAIK, AC_SUHU_TURUN, AC_KIPAS };

const uint32_t INTERVAL_DHT   = 2500;
const uint32_t INTERVAL_LAPOR = 5000;
const uint32_t TIMEOUT_MENU   = 15000;

// ---------- Ambang tombol ----------
const int AMB_RIGHT  = 60;
const int AMB_UP     = 200;
const int AMB_DOWN   = 380;
const int AMB_LEFT   = 555;
const int AMB_SELECT = 790;

// ============================================================
//  LAMPU MEJA - data raw NEC (PROGMEM)
// ============================================================
const uint16_t lampuOnOff[]   PROGMEM = {9002,4499, 569,558, 570,558, 570,559, 569,558, 570,558, 570,559, 570,558, 569,1708, 549,1707, 548,1708, 547,1708, 548,1708, 548,1708, 549,1708, 548,1708, 548,559, 569,559, 570,1708, 548,558, 569,559, 569,559, 569,558, 570,558, 569,559, 569,1708, 548,559, 568,1709, 547,1708, 548,1709, 547,1709, 548,1707, 548,1708, 548};
const uint16_t lampuMode[]    PROGMEM = {8880,4470, 530,570, 580,570, 530,570, 530,570, 580,570, 530,570, 530,570, 580,1720, 480,1720, 530,1720, 530,1720, 480,1720, 530,1720, 530,1720, 480,1720, 530,570, 530,1720, 530,570, 530,1720, 530,570, 530,570, 580,570, 530,570, 530,570, 580,570, 530,1720, 530,570, 530,1720, 480,1720, 530,1720, 530,1670, 530,1720, 530};
const uint16_t lampuTerang[]  PROGMEM = {8930,4420, 580,570, 580,520, 580,570, 530,570, 580,520, 580,570, 580,520, 580,1670, 580,1670, 530,1720, 530,1670, 580,1670, 580,1670, 530,1720, 530,1670, 580,520, 580,570, 580,1670, 530,570, 580,1670, 530,570, 580,520, 580,570, 530,570, 580,1670, 580,520, 580,1670, 580,520, 580,1670, 580,1670, 530,1720, 530,1670, 580};
const uint16_t lampuRedup[]   PROGMEM = {8930,4470, 530,570, 580,520, 580,570, 580,520, 580,570, 530,570, 580,520, 580,1720, 530,1670, 580,1670, 530,1720, 530,1670, 580,1670, 580,1670, 530,1720, 530,570, 580,520, 580,520, 580,1720, 530,1670, 580,520, 580,570, 530,570, 530,570, 580,1720, 530,1670, 580,520, 580,570, 530,1720, 530,1720, 530,1670, 580,1670, 580};
const uint16_t lampuTimer10[] PROGMEM = {8930,4420, 580,570, 580,520, 580,570, 530,570, 580,570, 530,570, 530,570, 580,1670, 580,1670, 530,1720, 530,1670, 580,1670, 530,1720, 530,1670, 580,1670, 580,570, 530,1670, 580,1670, 530,1720, 530,1720, 530,1670, 580,520, 580,570, 530,570, 580,520, 580,570, 580,520, 580,570, 530,570, 580,1670, 580,1670, 530,1720, 530};
const uint16_t lampuTimer30[] PROGMEM = {8930,4470, 580,570, 530,570, 580,570, 530,520, 580,570, 580,570, 530,570, 530,1720, 530,1720, 530,1670, 580,1670, 530,1720, 530,1720, 530,1670, 580,1670, 580,570, 530,520, 580,1720, 530,1670, 580,1670, 580,520, 580,520, 580,570, 580,570, 530,1670, 580,520, 580,570, 580,520, 580,1670, 580,1670, 530,1720, 530,1670, 580};

const uint8_t PANJANG_LAMPU = 67;

struct PerintahLampu {
  const char*     nama;
  const uint16_t* data;
};

const PerintahLampu menuLampu[] = {
  {"ON / OFF",       lampuOnOff},
  {"Ganti Mode",     lampuMode},
  {"Terang +",       lampuTerang},
  {"Redup  -",       lampuRedup},
  {"Timer 10 menit", lampuTimer10},
  {"Timer 30 menit", lampuTimer30}
};
const uint8_t JUMLAH_LAMPU = sizeof(menuLampu) / sizeof(menuLampu[0]);

// ============================================================
//  AC PANASONIC - berbasis state, frame dibangun di kode
// ============================================================
const uint16_t HDR_MARK   = 3500;
const uint16_t HDR_SPACE  = 1700;
const uint16_t BIT_MARK   = 430;
const uint16_t ONE_SPACE  = 1300;
const uint16_t ZERO_SPACE = 430;
const uint8_t  FREK_AC    = 38;   // kHz
const uint16_t JEDA_FRAME = 10;   // ms antar frame

const uint8_t preambleAC[8] = {0x02, 0x20, 0xE0, 0x04, 0x00, 0x00, 0x00, 0x06};

// State awal: ON, mode dingin, 25C, kipas auto
uint8_t acState[19] = {
  0x02, 0x20, 0xE0, 0x04, 0x00,
  0x39,   // [5] mode dingin + power ON
  0x32,   // [6] suhu 25C
  0x80,   // [7]
  0xA1,   // [8] kipas auto + swing
  0x00, 0x00, 0x0E, 0xE0,
  0x00, 0x00, 0x89,
  0x00, 0x00,
  0x00    // [18] checksum
};

const uint8_t kipasUrutan[] = {0xA, 0x3, 0x4, 0x5, 0x6, 0x7};   // A = auto
const uint8_t JUMLAH_KIPAS  = 6;

bool    acNyala() { return acState[5] & 0x01; }
uint8_t acSuhu()  { return acState[6] >> 1; }
uint8_t acKipas() { return acState[8] >> 4; }

void setSuhu(int8_t c) {
  if (c < 16) c = 16;
  if (c > 30) c = 30;
  acState[6] = c << 1;
}

void kipasBerikutnya() {
  uint8_t k = acKipas(), i = 0;
  for (; i < JUMLAH_KIPAS; i++) if (kipasUrutan[i] == k) break;
  i = (i + 1) % JUMLAH_KIPAS;
  acState[8] = (kipasUrutan[i] << 4) | (acState[8] & 0x0F);
}

void kirimFrameAC(const uint8_t* data, uint8_t jumlahByte) {
  IrSender.mark(HDR_MARK);
  IrSender.space(HDR_SPACE);
  for (uint8_t i = 0; i < jumlahByte; i++) {
    for (uint8_t b = 0; b < 8; b++) {            // LSB first
      IrSender.mark(BIT_MARK);
      IrSender.space((data[i] >> b) & 1 ? ONE_SPACE : ZERO_SPACE);
    }
  }
  IrSender.mark(BIT_MARK);                       // stop bit
}

void kirimAC() {
  uint8_t cs = 0;
  for (uint8_t i = 0; i < 18; i++) cs += acState[i];
  acState[18] = cs;                              // checksum

  Serial.flush();     // tuntaskan kiriman serial dulu, jangan menyela IR

  IrSender.enableIROut(FREK_AC);
  kirimFrameAC(preambleAC, 8);
  delay(JEDA_FRAME);
  IrSender.enableIROut(FREK_AC);
  kirimFrameAC(acState, 19);
}

// Aksi menu AC
struct PerintahAC {
  const char* nama;
  AksiAC      aksi;
};

const PerintahAC menuAC[] = {
  {"Power ON/OFF", AC_POWER},
  {"Suhu  +",      AC_SUHU_NAIK},
  {"Suhu  -",      AC_SUHU_TURUN},
  {"Ganti Kipas",  AC_KIPAS}
};
const uint8_t JUMLAH_AC = sizeof(menuAC) / sizeof(menuAC[0]);

// ============================================================
//  KATEGORI
// ============================================================
const uint8_t KAT_LAMPU  = 0;
const uint8_t KAT_AC     = 1;
const uint8_t KAT_SETJAM = 2;
const uint8_t JUMLAH_KATEGORI = 3;

const char* namaKategori(uint8_t i) {
  switch (i) {
    case KAT_LAMPU: return "LAMPU MEJA";
    case KAT_AC:    return "AC KAMAR";
    default:        return "SET JAM";
  }
}

uint8_t jumlahPerintah(uint8_t kat) {
  return (kat == KAT_LAMPU) ? JUMLAH_LAMPU : JUMLAH_AC;
}

// ============================================================
//  STATUS PROGRAM
// ============================================================
Layar layar = HOME;

uint8_t idxKategori = 0;
uint8_t idxPerintah = 0;

uint8_t  jam = 0, menit = 0, detik = 0;
bool     jamTersinkron = false;
uint32_t tickTerakhir = 0;

uint8_t setJ = 0, setM = 0, kolomSet = 0;

float    suhu = NAN, lembap = NAN;
uint32_t dhtTerakhir = 0, laporTerakhir = 0, aktivitasTerakhir = 0;

char    bufSerial[24];
uint8_t panjangBuf = 0;

// ============================================================
//  TOMBOL
// ============================================================
Tombol bacaTombol() {
  int adc = analogRead(BUTTON_PIN);
  if (adc > 900)        return NONE;
  if (adc < AMB_RIGHT)  return RIGHT;
  if (adc < AMB_UP)     return UP;
  if (adc < AMB_DOWN)   return DOWN;
  if (adc < AMB_LEFT)   return LEFT;
  if (adc < AMB_SELECT) return SELECT;
  return NONE;
}

Tombol ambilTombol() {
  static bool menungguLepas = false;
  Tombol b = bacaTombol();

  if (menungguLepas) {
    if (b == NONE) {
      delay(40);
      if (bacaTombol() == NONE) menungguLepas = false;
    }
    return NONE;
  }
  if (b != NONE) {
    delay(40);
    if (bacaTombol() == b) {
      menungguLepas = true;
      return b;
    }
  }
  return NONE;
}

void bersihkanTombol() {
  while (bacaTombol() != NONE) delay(10);
  delay(50);
}

// ============================================================
//  JAM
// ============================================================
void updateJam() {
  while (millis() - tickTerakhir >= 1000) {
    tickTerakhir += 1000;
    if (++detik >= 60) {
      detik = 0;
      if (++menit >= 60) {
        menit = 0;
        if (++jam >= 24) jam = 0;
      }
    }
  }
}

void cetak2Digit(uint8_t n) {
  if (n < 10) lcd.print('0');
  lcd.print(n);
}

// ============================================================
//  TAMPILAN
// ============================================================
void isiHome() {
  lcd.setCursor(4, 0);
  if (jamTersinkron) {
    cetak2Digit(jam);   lcd.print(':');
    cetak2Digit(menit); lcd.print(':');
    cetak2Digit(detik);
  } else {
    lcd.print("--:--:--");
  }

  lcd.setCursor(0, 1);
  if (isnan(suhu)) {
    lcd.print("Sensor: error  ");
  } else {
    lcd.print(suhu, 1);
    lcd.write(0xDF);
    lcd.print("C  ");
    lcd.print(lembap, 0);
    lcd.print("%RH ");
  }
  lcd.setCursor(15, 1);
  lcd.write(0x7E);
}

void layarHome() { lcd.clear(); isiHome(); }

void layarKategori() {
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("KATEGORI  ");
  lcd.print(idxKategori + 1);
  lcd.print('/');
  lcd.print(JUMLAH_KATEGORI);

  lcd.setCursor(0, 1);
  lcd.print('>');
  lcd.print(namaKategori(idxKategori));
  lcd.setCursor(15, 1);
  lcd.write(0x7E);
}

// Baris atas saat di menu AC: tampilkan kondisi AC saat ini
void barisStatusAC() {
  lcd.setCursor(0, 0);
  lcd.print("AC ");
  lcd.print(acNyala() ? "ON " : "OFF");
  lcd.print(' ');
  lcd.print(acSuhu());
  lcd.print("C ");

  uint8_t k = acKipas();
  if (k == 0xA) lcd.print("Aut");
  else        { lcd.print('F'); lcd.print(k - 2); lcd.print(' '); }
  lcd.print("  ");
}

void layarPerintah() {
  lcd.clear();

  if (idxKategori == KAT_AC) {
    barisStatusAC();
    lcd.setCursor(0, 1);
    lcd.print('>');
    lcd.print(menuAC[idxPerintah].nama);
  } else {
    lcd.setCursor(0, 0);
    lcd.print(namaKategori(idxKategori));
    lcd.setCursor(12, 0);
    lcd.print(idxPerintah + 1);
    lcd.print('/');
    lcd.print(JUMLAH_LAMPU);

    lcd.setCursor(0, 1);
    lcd.print('>');
    lcd.print(menuLampu[idxPerintah].nama);
  }
}

void layarSetJam() {
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("SET JAM  UP/DOWN");
  lcd.setCursor(5, 1);
  cetak2Digit(setJ);
  lcd.print(':');
  cetak2Digit(setM);
  lcd.setCursor(kolomSet == 0 ? 4 : 7, 1);
  lcd.print('[');
  lcd.setCursor(kolomSet == 0 ? 7 : 10, 1);
  lcd.print(']');
}

void gambarLayar() {
  switch (layar) {
    case HOME:           layarHome();     break;
    case PILIH_KATEGORI: layarKategori(); break;
    case PILIH_PERINTAH: layarPerintah(); break;
    case SET_JAM:        layarSetJam();   break;
  }
}

// ============================================================
//  EKSEKUSI PERINTAH
// ============================================================
void lapor(const char* kat, const char* cmd) {
  Serial.print(F("IR;KAT="));
  Serial.print(kat);
  Serial.print(F(";CMD="));
  Serial.println(cmd);
}

void jalankanLampu(uint8_t i) {
  if (i >= JUMLAH_LAMPU) return;

  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("Mengirim IR...");
  lcd.setCursor(0, 1);
  lcd.print(menuLampu[i].nama);

  Serial.flush();     // tuntaskan kiriman serial dulu, jangan menyela IR
  IrSender.sendRaw_P(menuLampu[i].data, PANJANG_LAMPU, 38);
  lapor("LAMPU MEJA", menuLampu[i].nama);

  lcd.setCursor(0, 0);
  lcd.print("Terkirim! [OK]  ");
  delay(700);
  bersihkanTombol();
  gambarLayar();
}

void jalankanAC(uint8_t i) {
  if (i >= JUMLAH_AC) return;

  switch (menuAC[i].aksi) {
    case AC_POWER:      acState[5] ^= 0x01;      break;
    case AC_SUHU_NAIK:  setSuhu(acSuhu() + 1);   break;
    case AC_SUHU_TURUN: setSuhu(acSuhu() - 1);   break;
    case AC_KIPAS:      kipasBerikutnya();       break;
  }

  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("Mengirim AC...");
  lcd.setCursor(0, 1);
  lcd.print(menuAC[i].nama);

  kirimAC();
  lapor("AC KAMAR", menuAC[i].nama);

  // Tampilkan kondisi AC yang baru
  lcd.clear();
  barisStatusAC();
  lcd.setCursor(0, 1);
  lcd.print("Terkirim! [OK]");
  delay(900);

  bersihkanTombol();
  gambarLayar();
}

void jalankanPerintah(uint8_t kat, uint8_t i) {
  if (kat == KAT_LAMPU)   jalankanLampu(i);
  else if (kat == KAT_AC) jalankanAC(i);
}

// ============================================================
//  SERIAL KE RASPBERRY PI
// ============================================================
void laporStatus() {
  Serial.print(F("STATUS;T="));
  if (isnan(suhu)) Serial.print(F("NA")); else Serial.print(suhu, 1);
  Serial.print(F(";H="));
  if (isnan(lembap)) Serial.print(F("NA")); else Serial.print(lembap, 0);

  Serial.print(F(";JAM="));
  if (jamTersinkron) {
    if (jam   < 10) Serial.print('0');  Serial.print(jam);   Serial.print(':');
    if (menit < 10) Serial.print('0');  Serial.print(menit); Serial.print(':');
    if (detik < 10) Serial.print('0');  Serial.print(detik);
  } else {
    Serial.print(F("NA"));
  }

  // Kondisi AC menurut Arduino
  Serial.print(F(";AC="));
  Serial.print(acNyala() ? F("ON") : F("OFF"));
  Serial.print(F(";ACT="));
  Serial.print(acSuhu());
  Serial.print(F(";ACF="));
  Serial.print(acKipas(), HEX);
  Serial.println();
}

void prosesBaris(char* baris) {

  // TIME=12:34:56
  if (strncmp(baris, "TIME=", 5) == 0) {
    int j, m, d;
    if (sscanf(baris + 5, "%d:%d:%d", &j, &m, &d) == 3) {
      if (j >= 0 && j < 24 && m >= 0 && m < 60 && d >= 0 && d < 60) {
        jam = j; menit = m; detik = d;
        tickTerakhir = millis();
        jamTersinkron = true;
        Serial.println(F("ACK;TIME"));
        if (layar == HOME) gambarLayar();
      }
    }
    return;
  }

  // SEND=kategori,perintah   (0=lampu, 1=AC)
  if (strncmp(baris, "SEND=", 5) == 0) {
    int a, b;
    if (sscanf(baris + 5, "%d,%d", &a, &b) == 2) jalankanPerintah(a, b);
    return;
  }

  // ACTEMP=24   set suhu AC langsung
  if (strncmp(baris, "ACTEMP=", 7) == 0) {
    int c = atoi(baris + 7);
    if (c >= 16 && c <= 30) {
      setSuhu(c);
      kirimAC();
      Serial.println(F("ACK;ACTEMP"));
      gambarLayar();
    }
    return;
  }

  // ACPOWER=ON / ACPOWER=OFF
  if (strncmp(baris, "ACPOWER=", 8) == 0) {
    if (strcmp(baris + 8, "ON") == 0)       acState[5] |=  0x01;
    else if (strcmp(baris + 8, "OFF") == 0) acState[5] &= ~0x01;
    else return;
    kirimAC();
    Serial.println(F("ACK;ACPOWER"));
    gambarLayar();
    return;
  }

  if (strcmp(baris, "PING") == 0) {
    Serial.println(F("PONG"));
    return;
  }
}

void bacaSerial() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (panjangBuf > 0) {
        bufSerial[panjangBuf] = '\0';
        prosesBaris(bufSerial);
        panjangBuf = 0;
      }
    } else if (panjangBuf < sizeof(bufSerial) - 1) {
      bufSerial[panjangBuf++] = c;
    }
  }
}

// ============================================================
void setup() {
  Serial.begin(9600);
  lcd.begin(16, 2);
  dht.begin();
  IrSender.begin(IR_SEND_PIN);

  lcd.setCursor(0, 0);
  lcd.print("== SMART ROOM ==");
  lcd.setCursor(0, 1);
  lcd.print("  Booting...    ");
  delay(1500);

  suhu   = dht.readTemperature();
  lembap = dht.readHumidity();

  tickTerakhir = dhtTerakhir = laporTerakhir = aktivitasTerakhir = millis();

  Serial.println(F("READY;SMARTROOM"));
  gambarLayar();
}

void loop() {
  updateJam();
  bacaSerial();

  if (millis() - dhtTerakhir >= INTERVAL_DHT) {
    dhtTerakhir = millis();
    float t = dht.readTemperature();
    float h = dht.readHumidity();
    if (!isnan(t) && !isnan(h)) { suhu = t; lembap = h; }
    else                        { suhu = NAN; lembap = NAN; }
  }

  // Lapor STATUS hanya saat idle (HOME), supaya tidak menabrak
  // pengiriman IR yang timing-nya sensitif
  if (layar == HOME && millis() - laporTerakhir >= INTERVAL_LAPOR) {
    laporTerakhir = millis();
    laporStatus();
  }

  if (layar == HOME) {
    static uint8_t detikTampil = 255;
    if (detik != detikTampil) {
      detikTampil = detik;
      isiHome();
    }
  }

  if (layar != HOME && millis() - aktivitasTerakhir >= TIMEOUT_MENU) {
    layar = HOME;
    gambarLayar();
  }

  Tombol t = ambilTombol();
  if (t == NONE) return;
  aktivitasTerakhir = millis();

  switch (layar) {

    case HOME:
      if (t == SELECT || t == RIGHT) {
        layar = PILIH_KATEGORI;
        idxKategori = 0;
        gambarLayar();
      }
      break;

    case PILIH_KATEGORI:
      if (t == UP) {
        idxKategori = (idxKategori == 0) ? JUMLAH_KATEGORI - 1 : idxKategori - 1;
        gambarLayar();
      } else if (t == DOWN) {
        idxKategori = (idxKategori + 1) % JUMLAH_KATEGORI;
        gambarLayar();
      } else if (t == RIGHT || t == SELECT) {
        if (idxKategori == KAT_SETJAM) {
          setJ = jam; setM = menit; kolomSet = 0;
          layar = SET_JAM;
        } else {
          idxPerintah = 0;
          layar = PILIH_PERINTAH;
        }
        gambarLayar();
      } else if (t == LEFT) {
        layar = HOME;
        gambarLayar();
      }
      break;

    case PILIH_PERINTAH: {
      uint8_t total = jumlahPerintah(idxKategori);
      if (t == UP) {
        idxPerintah = (idxPerintah == 0) ? total - 1 : idxPerintah - 1;
        gambarLayar();
      } else if (t == DOWN) {
        idxPerintah = (idxPerintah + 1) % total;
        gambarLayar();
      } else if (t == SELECT) {
        jalankanPerintah(idxKategori, idxPerintah);
      } else if (t == LEFT) {
        layar = PILIH_KATEGORI;
        gambarLayar();
      }
      break;
    }

    case SET_JAM:
      if (t == UP) {
        if (kolomSet == 0) setJ = (setJ + 1) % 24;
        else               setM = (setM + 1) % 60;
        gambarLayar();
      } else if (t == DOWN) {
        if (kolomSet == 0) setJ = (setJ == 0) ? 23 : setJ - 1;
        else               setM = (setM == 0) ? 59 : setM - 1;
        gambarLayar();
      } else if (t == RIGHT) {
        kolomSet = 1 - kolomSet;
        gambarLayar();
      } else if (t == SELECT) {
        jam = setJ; menit = setM; detik = 0;
        tickTerakhir = millis();
        jamTersinkron = true;
        lcd.clear();
        lcd.setCursor(0, 0);
        lcd.print("Jam disimpan!");
        delay(800);
        layar = HOME;
        gambarLayar();
      } else if (t == LEFT) {
        layar = PILIH_KATEGORI;
        gambarLayar();
      }
      break;
  }
}
