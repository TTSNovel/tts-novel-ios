# Reading History Sync — thiết kế

Trạng thái: phía Apple (Core, iOS, macOS, watchOS) đã cài đặt · 2026-11-03 · phạm vi: tts-webnovel (server + web reader), tts-novel-ios (iOS, macOS, watchOS)

Hợp đồng API (tên field, mã trạng thái) ở mục 5 là bản chung server/web/Apple đang cài đặt song song; tài liệu này mô tả thêm phía client Apple như đã cài đặt.

## 1. Bối cảnh & sự cố

2026-11-03, sách "Bắc Âm Đại Thánh":

- 11:19:21 UTC — iPhone đẩy chương 441 (log Cloud Run, UA `WebnovelReader/... Darwin`).
- 11:22:59, 11:23:28, 11:23:34 — tab Firefox trên NixOS (UA `Firefox/159 X11 Linux`) đang mở chương 297 đẩy 3 lần.
- 11:25:31 — Mac `refreshFromServer` → `adoptRemoteChapter` → "Follow chapter from another device — chapter 297".
- 11:28:15 — iPhone cũng theo 297 và đẩy lại. Vị trí 441 mất hẳn, không có chỗ nào để khôi phục.

Đã xảy ra nhiều lần trước đó (vd 10:45 Mac nhảy 435 → 325, chưa truy được nguồn vì server không ghi thiết bị).

## 2. Nguyên nhân gốc (mô hình, không phải một dòng code)

1. **Server chỉ lưu 1 giá trị "hiện tại" per book, last-write-wins theo đồng hồ server.** Mọi POST đều thắng, kể cả POST lặp lại một giá trị cũ. Không có lịch sử → không có đường lui.
2. **Không phân biệt ý định (intent) với trạng thái (state).** Một client "nhắc lại chỗ mình đang đứng" (web reader khi tab bị ẩn/đóng/pause/load) được coi như người dùng vừa chọn chương đó.
3. **Không có danh tính thiết bị.** Server không biết ai ghi; client không biết thay đổi từ xa đến từ đâu, nên không thể hỏi người dùng một câu có nghĩa.
4. **Server nhận cả lần ghi từ thiết bị chưa biết vị trí mới nhất** (tab mở từ trước khi đọc tới 441). Các thiết bị khác tự theo là đúng; sai ở chỗ một giá trị stale được phép thành position.
5. (Phụ) progress.json là 1 file chung cho mọi sách trên GCS FUSE, Cloud Run tới 10 instance × concurrency 8 → read-modify-write có thể mất update hoặc đọc bản cache cũ.

Commit iOS d82a95e đã vá (2) phía app, nhưng mô hình vẫn để bất kỳ client nào khác (web, build cũ, watch) tái phát.

## 3. Mục tiêu

- G1. Không client nào có thể làm mất vị trí đọc: mọi thay đổi đều nằm trong lịch sử append-only, khôi phục được bằng 1 thao tác.
- G2. Chỉ hành động có chủ đích của người dùng mới được đổi vị trí đọc.
- G3. Một thay đổi chỉ được áp dụng khi thiết bị ghi đã biết vị trí mới nhất (causality). Hướng đi (tiến/lùi) không phải tín hiệu: đọc lại chương cũ là hành động hợp lệ. Thiết bị "lạc hậu" (stale) không được ghi đè âm thầm — người dùng được hỏi ngay trên thiết bị đó, nơi họ đang thao tác.
- G4. Biết được thiết bị nào ghi gì, lúc nào.
- G5. Tương thích ngược trong thời gian rollout (build iOS cũ qua SideStore, web reader cache trong service worker).

Ngoài phạm vi: đồng bộ vị trí câu (sentence) — vẫn per chapter như d82a95e; nhiều tài khoản.

## 4. Khái niệm

- **Device**: `device_id` (UUID sinh 1 lần; iOS/macOS/watchOS lưu file `device-id.json` trong Application Support — `DeviceIdentity`; web lưu localStorage `deviceId`) + `device_name` hiển thị ("iPhone"/"iPad" theo model identifier, tên máy Mac hoặc "Mac", "Apple Watch", "Firefox · Linux"). Gửi qua header `X-Device-Id` và `X-Device-Name` (percent-encoded UTF-8) trên mọi request (`APIClient.perform`). Thiếu header → server suy `device_name` từ User-Agent, `device_id = null`.
- **ReadingEvent** (append-only, bất biến):
  - `id` (UUID do client sinh → idempotent khi retry)
  - `book_id`, `chapter`, `prev_chapter`
  - `kind`: `select` (chọn chương từ danh sách / prev / next / swipe / skip), `auto_next` (hết chương tự sang), `restore` (khôi phục từ lịch sử hoặc "đọc ở đây" sau xung đột), `legacy` (POST kiểu cũ)
  - `base_rev`: revision client thấy lần cuối khi ra quyết định (`null` với legacy)
  - `device_id`, `device_name`, `client_ts`, `server_ts`
  - `applied: bool`, `conflict: bool` (`base_rev` khác rev hiện tại lúc nhận → bị từ chối)
  - `rev`: rev của position sau khi xử lý event này
- **Position** (materialized, per book): `{chapter, sentence: 0, updated_at, rev, device_id, device_name}`. `sentence` chỉ giữ để client cũ decode được. `rev` tăng đơn điệu mỗi lần position đổi.

Quy tắc nền: **mở lại chỗ đã lưu (resume), tab ẩn, pause/stop, app vào background, theo thay đổi từ xa → KHÔNG tạo event.** Chỉ `select`/`auto_next`/`restore` tạo event.

## 5. Server (tts-webnovel)

### 5.1 Lưu trữ

Một object per book: `progress/<book_id>.json` = `{"position": Position|null, "events": [Event cũ→mới, tối đa 500]}`.

- Ghi qua GCS JSON API với `ifGenerationMatch` (compare-and-swap, `0` = chưa tồn tại) khi chạy trên Cloud Run; khi 412 đọc lại và xét lại luật từ bước 2, tối đa 5 lần rồi 503. Không đi qua FUSE mount cho file này → hết race giữa instance và hết đọc cache cũ. Chạy local/test: backend thư mục `SITE_DIR/progress/` với kiểm tra generation tương đương.
- File per book → ghi sách A không đụng sách B.
- Chi phí: vài chục KB/sách, vài chục write/ngày — không đáng kể, giữ đúng mặc định "GCS rẻ nhất".
- Migration: sách chưa có file v2 nhưng có trong `progress.json` cũ → seed position `{chapter, rev: 1, device_name: "(migrated)"}` + 1 event `kind=legacy, applied=true`. `progress.json` cũ không còn được ghi.

### 5.2 API

- `GET /api/progress` → `{"<book_id>": Position}`. Giữ field `chapter`, `sentence`, `updated_at` cũ để client cũ vẫn đọc được.
- `GET /api/progress/<book_id>/history?limit=N` (mặc định 100, tối đa 500) → `{"position": Position|null, "events": [Event mới nhất trước]}`.
- `POST /api/progress/events` body `{id, book_id, chapter, kind, base_rev, client_ts?}` → 200 hoặc 409, cả hai đều trả `{"position", "event"}`.
- `POST /api/progress` (cũ) → event `kind=legacy` (xem 5.4).

### 5.3 Luật áp dụng event (theo thứ tự)

1. Body sai → 400.
2. `id` đã có trong events của sách → trả lại đúng kết quả cũ (cùng status 200/409), không ghi.
3. `chapter == position.chapter` → ghi event `applied=false, conflict=false` (no-op), không tăng rev → 200.
4. `base_rev == position.rev` (sách chưa có position: rev 0) → áp dụng, `rev += 1`, `updated_at`/thiết bị = request → 200. Bất kể tiến hay lùi bao nhiêu chương.
5. `base_rev != position.rev` → ghi event `applied=false, conflict=true` → **409**, kèm `position` hiện tại (chương, thiết bị, giờ). Client hỏi người dùng (6.3); nếu người dùng xác nhận thì gửi `restore` với `base_rev` mới → rơi vào luật 4.

Vì sao đúng với sự cố: tab Firefox load chương 297 từ trước khi iPhone nghe tới 441, nên `base_rev` của nó cũ hơn → 409, position giữ 441. Còn nếu người dùng ở iPhone (đã thấy 441) chủ động mở lại chương 297 thì `base_rev` khớp → áp dụng, mọi thiết bị theo 297 — đúng ý muốn đọc lại.

Không có luật nào xoá hay sửa event → G1.

### 5.4 Tương thích ngược (G5)

Biến môi trường `PROGRESS_LEGACY_MODE`:

- `apply` (mặc định, pha A): legacy POST vẫn áp dụng như hôm nay nếu chương khác (rev+1), nhưng được ghi event `kind=legacy, base_rev=null` kèm `device_name` suy từ User-Agent → đã có lịch sử và khôi phục được ngay.
- `log` (pha B, sau khi web + iOS + watch đã lên API mới): legacy POST chỉ ghi vào lịch sử với `applied=false`, không đổi position. Build cũ còn sót lại không thể phá vị trí nữa.

## 6. Client — luật chung (iOS, macOS, watchOS, web)

Phía Apple: logic nằm trong Core (`ProgressStore`, `ProgressReconciler`, `DeviceIdentity`, model ở `Models/ReadingEvent.swift`); app chỉ báo ý định và hiển thị.

`ProgressStore` giữ 2 góc nhìn per book:

- `progress` — chương thiết bị này **hiển thị** (dòng Library, "Đọc tiếp", chỗ reader resume). Đổi ngay khi người dùng thao tác. Lưu `progress.json` (file cũ, entry thiếu `rev` decode thành 0).
- `serverProgress` — position server cuối cùng thiết bị này **chấp nhận**; `rev` của nó là `base_rev` cho lần ghi kế tiếp. Lưu `progress-server.json`.

### 6.1 Ghi

- `record(bookID:chapterIndex:kind:)` — tạo event chỉ ở: chọn chương (list, prev/next, swipe, remote next/prev → `select`), auto-next (`auto_next`), restore. Chương bằng chương đang hiển thị → no-op (trừ `restore`, luôn gửi).
- `open()` ở chương đang hiển thị (resume) → không ghi. Mở chương khác → `select`.
- Theo thiết bị khác, "Chuyển tới chương N" → điều hướng **không** ghi (`adoptServer` đặt chương hiển thị = server trước, nên `record` của goTo/skip là no-op).
- Outbox persisted (`progress-outbox.json`, thay cờ `unsynced` + `progress-unsynced.json` cũ — file cũ bị xoá khi khởi động, sách trong đó lấy lại vị trí ở lần refresh đầu tiên): gửi lần lượt theo thứ tự, lỗi mạng/5xx/404 → dừng, lần sau gửi lại cùng `id` (sau mỗi `record`, mỗi refresh, rời reader/background, rời màn phát trên watch). 400 → bỏ event (gửi lại cũng không bao giờ được), ghi log lỗi.
- `base_rev` cố định lúc tạo event. Ngoại lệ: nhiều event cùng sách nằm chờ (offline đọc 5 → 6 → 7) — khi event trước được áp dụng (200, `applied=true`), các event sau cùng `base_rev` được đổi sang rev mới, vì chúng được quyết định dựa trên chính event đó.
- Khách (chưa đăng nhập): chỉ đổi chương hiển thị, không xếp event, không gửi.

### 6.2 Nhận thay đổi từ xa (reconcile)

Mọi position trên server đều đến từ một thiết bị đã biết vị trí mới nhất (luật 5.3), nên thiết bị nhận **tin nó, không xét hướng**. Khi refresh (launch, iOS foreground, Mac `didBecomeActive`, watch mở thư viện, web tab visible) hoặc mở timeline của sách, mỗi position đi qua hàm thuần `ProgressReconciler.decide(knownRev:displayedChapter:remote:hasPendingEvents:isPlaying:selfDeviceID:)`:

1. `remote.rev <= known.rev` → `ignore`.
2. `remote.device_id == mình`, hoặc sách còn event trong outbox → `acknowledge`: chỉ cập nhật `serverProgress`, giữ chương hiển thị (với outbox: kết quả gửi sẽ quyết định).
3. Cùng chương với chương hiển thị → `acknowledge`.
4. Sách đang được nghe trên máy này (`ProgressStore.playingBookID`, do ReaderPlaybackController/WatchPlaybackController đặt khi đang phát, đang chờ audio câu, hoặc giữa 2 chương khi auto-next; xoá khi pause/stop) → `notify`: không đổi chương hiển thị **và không tăng `serverProgress.rev`**, chỉ publish `remoteNotices[book]` ("iPhone đã chuyển sang chương X — [Chuyển] [×]"). Lần ghi kế tiếp của máy này (vd auto-next) sẽ bị 409 → hỏi theo 6.3. Như vậy hai phiên nghe song song không âm thầm giành nhau. Bỏ qua (×) → không hiện lại cho cùng rev.
5. Còn lại (đang rảnh) → `follow`: chương hiển thị = remote (tiến hay lùi), trả về trong map `[bookID: chapter]` để reader đang mở (không phát) đi theo.

### 6.3 Xung đột khi ghi (409)

Hiện trên chính thiết bị vừa thao tác, vì người dùng đang ở đó và có ngữ cảnh. 409 → bỏ event (và mọi event cùng sách còn chờ, vốn dựa trên nó) khỏi outbox, `serverProgress` = position server trả về (thiết bị giờ đã "biết"), giữ chương hiển thị, publish `conflicts[book] = {bookID, attemptedChapter, kind, server}`. Nếu chương hiển thị lúc đó đã trùng chương server thì không có gì để hỏi — chỉ cập nhật.

Banner trong reader (`ReadingSyncBanner`, overlay phía trên, không đổi layout pager):

"iPhone đang ở chương 441 (18:19). [Đọc chương 298 ở đây] [Chuyển tới chương 441] [Lịch sử]"

- "Đọc ở đây" → `keepLocal`: gửi `restore` cho chương hiển thị với `base_rev` mới → áp dụng, các thiết bị khác theo.
- "Chuyển tới" → `adoptServer` + điều hướng không ghi (đang phát thì phát tiếp sang chương đó như skip, không dừng).
- "Lịch sử" → sheet `BookReadingHistoryView`.
- `auto_next` bị 409 → không ngắt audio, phát tiếp chương kế tại chỗ, banner không chặn. Trong lúc xung đột chưa được trả lời, các `auto_next` tiếp theo chỉ đổi chương hiển thị (banner cập nhật "Đọc chương M ở đây"), không gửi — dù `base_rev` giờ đã mới, playlist tự chạy không phải là người dùng chọn ghi đè. `select`/`restore` thì gửi và xoá banner (người dùng thao tác khi đã thấy banner).
- Request ghi lỗi mạng → event nằm trong outbox; khi gửi được mà bị 409 thì vẫn hỏi như trên (không tự ghi đè).

### 6.4 Lịch sử & khôi phục (G1)

- `BookReadingHistoryView` (iOS/Mac), mở từ BookDetailView (nút đồng hồ, chỉ khi đã đăng nhập) và từ banner xung đột: timeline `GET /api/progress/<id>/history` — mỗi dòng: chương, thiết bị, giờ, loại (chọn chương / tự sang chương / khôi phục / bản cũ); event không áp dụng bị làm mờ, ghi "xung đột" hoặc "không áp dụng".
- Bấm một dòng → xác nhận "Đọc tiếp từ chương N?" → `record(.restore)` rồi mở reader ở chương đó.
- Màn "Lịch sử đọc" hiện có (danh sách sách) giữ nguyên.
- Watch: dùng luật 6.1/6.2 (`select`/`auto_next` ghi ngay khi đổi chương, refresh lúc mở thư viện để có `base_rev` hiện tại), không có UI timeline/banner — xung đột chỉ chặn auto-next ghi đè; giải quyết trên iPhone/Mac.

## 7. Web reader (reader.js)

- Giữ `base_rev` của lần GET gần nhất; refresh khi tab visible trước khi cho phép ghi.
- Bỏ toàn bộ ghi ở `visibilitychange`, `pagehide`, `pause`, `stop`, và nhánh "baseline" của `applyResumeOrBaseline`.
- Ghi event `select` khi người dùng bấm link chương / prev / next; `auto_next` khi hết chương. Phân biệt "người dùng điều hướng" với "trang được khôi phục" bằng một flag `sessionStorage` đặt lúc click, cộng `performance.getEntriesByType('navigation')[0].type` (`reload`, `back_forward` → không phải intent).
- Tab trở lại visible → GET và áp dụng luật 6.2. 409 → banner trong trang theo 6.3.
- Bump version `sw.js` để tab cũ lấy reader.js mới.

## 8. Quan sát

- Quyết định reconcile và xung đột ghi vào `Log` (category `sync`) và EventLogStore (tiếng Anh) kèm device_name, rev: "Remote chapter followed", "Remote chapter not followed while playing", "Chapter change conflicts with another device", "Kept this device's chapter over another device's", "Moved to another device's chapter", "Reading event accepted / rejected as stale / not sent, will retry".
- Server log 1 dòng structured per event (book, chapter, kind, device, applied, conflict) → truy vết như sự cố 10:45 trong vài giây.

## 9. Kiểm thử

- Core unit test (`swift test` trong `Packages/Core`, không gọi server — `ProgressStore` nhận `ProgressSyncing` giả lập đúng luật 5.3):
  - `ProgressReconcilerTests`: toàn bộ bảng quyết định 6.2.
  - `ProgressStoreTests`: select áp dụng; resume không ghi; restore luôn gửi; replay sự cố (base cũ ghi 297 khi server 441 → 409, server giữ 441, banner; "đọc ở đây" → áp dụng); adoptServer không ghi; đọc lại chương cũ với base mới → áp dụng; outbox retry cùng `id`; chuỗi event offline được rebase; outbox sống qua relaunch; khách không gửi; máy rảnh theo lùi; máy đang nghe → notice, auto-next kế tiếp → 409, auto-next sau đó không ghi đè; notice đã bỏ qua không quay lại; `progress.json` cũ thiếu `rev` vẫn load; body event đúng hợp đồng.
- Server pytest: luật 5.3, legacy pha A/B, CAS với 2 writer song song (mock generation mismatch), migration từ progress.json.
- Không viết UI test đẩy progress lên server: UI test chạy với server và tài khoản thật, ghi progress ở đó làm hỏng lịch sử đọc thật.

## 10. Rollout

1. Server: storage per book + CAS + event API + legacy pha A + history GET. (Có lịch sử ngay từ đây.)
2. Web reader: luật ghi mới + reconcile + timeline.
3. Core/iOS/Mac/watch: device id, outbox, `ProgressReconciler`, banner, timeline.
4. Chờ SideStore cập nhật iPhone + Mac Sparkle cập nhật (≥ 1 ngày) → bật legacy pha B.

## 11. Câu hỏi mở

- Pha A (trước khi web/watch lên API mới) legacy POST vẫn áp dụng, nên sự cố kiểu Firefox vẫn có thể xảy ra trong pha này — chỉ khác là khôi phục được. Muốn chặn sớm hơn thì ra web reader cùng lúc với server.
- Giới hạn lịch sử 500 event/sách có đủ không (~ vài tháng nghe liên tục)?
