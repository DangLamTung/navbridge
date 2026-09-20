# NavBridge Voice / TTS Phrase Inventory

> The complete list of Vietnamese phrases the app speaks via Android `TextToSpeech`
> (the `VoiceGuide` service). Phrases are built at runtime from a small set of
> templates + helper functions, so the "voice pack" is a **phrase catalog** (templates +
> fixed strings), and a few numeric/name placeholders.
>
> The voice is Vietnamese (`vi-VN`). All guidance uses
> `USAGE_ASSISTANCE_NAVIGATION_GUIDANCE` → plays over a connected Bluetooth speaker.

---

## 1. Turn-by-turn maneuvers (`nav_voice.dart` → `_announce`)

Templates combine: **verb** (from `maneuverVerb`) + **into-road** + **next-next** +
**speed-limit**. Two forms:

- **Head-up (not yet close):** `Đi<onRoad>, sau <distance>, <verb><into><nextNext>.<limitTxt>`
  - e.g. `Đi trên Nguyễn Huệ, sau 350 mét, rẽ phải vào Đồng Khởi. Tốc độ tối đa 50 km/h.`
- **Final (close):** `<verb><into><nextNext>.<limitTxt>`
  - e.g. `Rẽ phải vào Đồng Khởi. Tốc độ tối đa 50 km/h.`
- **Arrival:** `Bạn đã đến nơi.` or `Điểm đến bên trái.` / `Điểm đến bên phải.`

### Maneuver verbs (`nav_protocol.dart`)
| code | verb |
|---|---|
| turn left | `rẽ trái` |
| turn right | `rẽ phải` |
| slight left | `rẽ trái nhẹ` |
| slight right | `rẽ phải nhẹ` |
| U-turn | `quay đầu` |
| roundabout | `đi theo vòng xuyến` |
| arrive | `đến nơi` |
| default | `đi thẳng` |

### Distance words (`formatDistanceSpoken`)
- `< n` : `«mét »` → `350 mét`
- `≥ n` : `«km »` → `1,2 km`

---

## 2. Road signs (`nav_signs.dart`)

Every sign has a **near** (≤100 m) and **far** form. The far form appends
`phía trước <distance>`.

| Sign | near | far |
|---|---|---|
| STOP | `Biển STOP sắp tới` | `Biển STOP phía trước 350 mét` |
| Give-way | `Biển nhường đường sắp tới` | `Biển nhường đường phía trước …` |
| No passing | `Cấm vượt sắp tới` | `Cấm vượt phía trước …` |
| No left turn | `Cấm rẽ trái sắp tới` | `Cấm rẽ trái phía trước …` |
| No right turn | `Cấm rẽ phải sắp tới` | `Cấm rẽ phải phía trước …` |
| No U-turn | `Cấm quay đầu sắp tới` | `Cấm quay đầu phía trước …` |
| No left + U-turn | `Cấm rẽ trái và quay đầu sắp tới` | `Cấm rẽ trái và quay đầu phía trước …` |
| No right + U-turn | `Cấm rẽ phải và quay đầu sắp tới` | `Cấm rẽ phải và quay đầu phía trước …` |
| End no passing | `Hết cấm vượt sắp tới` | `Hết cấm vượt phía trước …` |
| Only straight | `Chỉ đi thẳng sắp tới` | `Chỉ được đi thẳng phía trước …` |
| Only right | `Chỉ rẽ phải sắp tới` | `Chỉ được rẽ phải phía trước …` |
| Only left | `Chỉ rẽ trái sắp tới` | `Chỉ được rẽ trái phía trước …` |
| End prohibitions | `Hết mọi lệnh cấm sắp tới` | `Hết mọi lệnh cấm phía trước …` |
| Slow down | `Giảm tốc độ sắp tới` | `Giảm tốc độ phía trước …` |
| Toll booth | `Trạm thu phí sắp tới` | `Trạm thu phí phía trước …` |
| Railway crossing | `Đường ngang giao với đường sắt sắp tới` | `Đường ngang giao với đường sắt phía trước …` |
| Tunnel | `Hầm đường bộ sắp tới` | `Hầm đường bộ phía trước …` |
| No car | `Cấm ô tô sắp tới` | `Cấm ô tô phía trước …` |
| No motorbike | `Cấm xe máy sắp tới` | `Cấm xe máy phía trước …` |
| No parking | `Cấm đỗ xe sắp tới` | `Cấm đỗ xe phía trước …` |
| No straight | `Cấm đi thẳng sắp tới` | `Cấm đi thẳng phía trước …` |
| No turn both | `Cấm rẽ trái và rẽ phải sắp tới` | `Cấm rẽ trái và rẽ phải phía trước …` |
| One-way | `Đường một chiều sắp tới` | `Đường một chiều phía trước …` |
| Reserved lane | `Làn dành riêng sắp tới` | `Làn dành riêng phía trước …` |
| Traffic light | `Đèn giao thông sắp tới` | `Đèn giao thông phía trước …` (near-only) |

> The "khu đông dân cư" (built-up boundary) phrases were **removed** together
> with the boundary layer itself — 9,211 points (20.4% of the sign DB) buying a
> built-up cap that never fired on any recorded drive and that contradicts the
> posted Waze segment value 39% of the time it does land on one. The limit is
> now posted signs + the road's own value only.

---

## 3. Cameras (`nav_weather.dart`)

Camera head varies by real type, then appends distance.

### Camera heads
| case | head |
|---|---|
| speed + limit | `Camera tốc độ <X> km/h` |
| speed | `Camera tốc độ` |
| traffic | `Camera giám sát giao thông` |
| penalty | `Camera phạt nguội` |
| red light | `Camera đèn đỏ` |
| focus=speed | `Camera tốc độ` |
| focus=red_light | `Camera đèn đỏ` |
| focus=violations | `Camera phạt nguội` |
| unconfirmed | `Có thể có camera` |
| default | `Camera` |

### Camera templates
- **near:** `<head><segment> ngay phía trước`
- **far:** `<head><segment> phía trước <distance>`
- `<segment>` (only when an enforcement segment length is known): ` trên đoạn <distance>`

---

## 4. Speed (`nav_voice.dart`)
| Event | phrase |
|---|---|
| Speed-limit change | `Giới hạn <X> km/h` |
| Overspeed (mild 5–10) | `Vượt quá tốc độ <X> km/h.` |
| Overspeed (strong) | `Giảm tốc độ! Vượt quá tốc độ.` |
| Motorbike on motorway | `Chú ý! Xe mô tô không được phép đi vào đường cao tốc. Xin thoát cao tốc khi có thể.` |

---

## 5. Weather (`nav_weather.dart`)
| Event | phrase |
|---|---|
| Rain ahead + km | `Trời đang mưa phía trước, cách đây khoảng <X> ki lô mét.` |
| Rain ahead (no km) | `Trời đang mưa trên tuyến đường phía trước.` |
| Rain likely | `Trời sắp mưa trên tuyến đường phía trước, xác suất <P> phần trăm.` |

---

## 6. Search / navigation state (`nav_search.dart`, `nav_voice.dart`)
| Event | phrase |
|---|---|
| Prompt | `Bạn muốn tìm địa điểm nào?` |
| Searching | `Đang tìm <loại>…` |
| Found + route | `Đã tìm thấy <tên>, bắt đầu chỉ đường.` |
| Not found | `Không tìm thấy địa điểm <query>.` |
| Found | `Đã tìm thấy <tên>.` |
| Start route | `Bắt đầu chỉ đường.` |
| Stop route | `Đã dừng chỉ đường.` |
| Voice on | `Đã bật hướng dẫn bằng giọng nói.` |
| Voice off | `Đã tắt nghe liên tục.` |
| Listening | `Nghe rồi, nói lệnh đi.` |
| GPS weak | `Tín hiệu GPS yếu, vị trí có thể không chính xác.` |
| AI prompt | `Bạn muốn hỏi AI điều gì?` |
| AI not understood | `Xin lỗi, tôi không hiểu lệnh.` |
| Voice help | `Bạn có thể nói: chỉ đường tới chợ Bến Thành, bắt đầu, dừng lại, phóng to, thu nhỏ, bật tiếng, tắt tiếng, nghe luôn, hỏi AI.` |
| Hard sections | `còn <X> km đến điểm đến` · `<n> đoạn đèo` · `<n> hầm` · `<n> đường ngang giao với đường sắt` · `<n> đoạn giảm tốc độ` · `<n> đoạn cấm vượt` · `<X> km đường uốn gắt` |

---

## 7. Placeholders

| token | meaning |
|---|---|
| `<distance>` | `formatDistanceSpoken(m)` → `350 mét` / `1,2 km` |
| `<X> km/h` | integer speed limit |
| `<tên>` / `<loại>` / `<query>` | place name / category / query text |
| `<segment>` | ` trên đoạn …` (camera enforcement length) |
| `<P>` | rain probability percentage |
| `<X> km` | remaining / winding km |
| `<n>` | count of hazards/passes |

---

## 8. How a voice pack would work

A "voice pack" = a **machine-readable catalog** of the above fixed strings + templates,
so another TTS voice / speaker can be generated or the strings overridden without
touching the navigation logic. Two useful artifacts:

1. **`pphrasess.json`** (the catalog) — emitted by `tools/build_voice_pack.py`.
2. Optional **audio clips** per line — if you want pre-recorded speaker clips instead of
   the system TTS (NOT currently used; the app calls `FlutterTts.speak(text)` at runtime).

Run the generator to produce the catalog:
```bash
python3 tools/build_voice_pack.py   # writes tools/voice_phrases.json (111 phrases)
```
