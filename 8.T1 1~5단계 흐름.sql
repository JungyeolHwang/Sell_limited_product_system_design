1) 흐름 그림 (한 장)
클라이언트 ── POST /reserve(sku, qty, idem_key)
        │
        ▼
[앱서버]  ── BEGIN T1
   1) 멱등성 등록 (idempotency)
      └ UNIQUE(user_id, idem_key)로 "이 요청은 내가 처리 중" 깃발
   2) 동시중복 방지 (user_active_hold)
      └ PRIMARY(sale_id, user_id)로 "이 세일에서 이 유저는 1개만"
   3) 전광판 숫자 줄이기 (inventory_counter)
      └ 조건부 단일 UPDATE: available >= qty 일 때만 감소
   4) 예약 생성 (reservation_hold, TTL)
      └ 상태=HOLD, expire_at=NOW()+5m
   5) 영수증 남기기 (inventory_ledger)
      └ 'RESERVE_DEBIT', qty_delta = -qty (불변 INSERT)
   ── COMMIT T1
        │
        └─ 응답: hold_id, expire_at


전광판 = inventory_counter : 현재 재고 숫자만 빠르게 보여줌

영수증함 = inventory_ledger : 언제/왜/얼마나 바뀌었는지 기록(INSERT 전용)

2) 테이블 요약 (핵심 4개)
-- 멱등성: 같은 요청은 한 번만
CREATE TABLE idempotency(
  user_id BIGINT, idem_key CHAR(36), request_hash BINARY(32),
  status ENUM('IN_PROGRESS','SUCCEEDED','FAILED'),
  response_json JSON, created_at DATETIME, updated_at DATETIME,
  UNIQUE KEY uq(user_id, idem_key)
);

-- 동시중복 방지용 깃발(가벼운 표)
CREATE TABLE user_active_hold(
  sale_id BIGINT, user_id BIGINT, sku_id BIGINT,
  hold_id BIGINT NULL, expire_at DATETIME NULL,
  PRIMARY KEY (sale_id, user_id)
);

-- 전광판(현재 재고)
CREATE TABLE inventory_counter(
  sku_id BIGINT PRIMARY KEY,
  available INT NOT NULL CHECK (available >= 0)
);

-- 예약(결제 전 임시 점유)
CREATE TABLE reservation_hold(
  hold_id BIGINT PRIMARY KEY, sale_id BIGINT, sku_id BIGINT, user_id BIGINT,
  qty INT, status ENUM('HOLD','COMMITTED','EXPIRED','CANCELLED'),
  expire_at DATETIME, created_at DATETIME,
  KEY(expire_at), KEY(user_id, sku_id, status, expire_at)
);

-- 영수증(불변 원장)
CREATE TABLE inventory_ledger(
  ledger_id BIGINT PRIMARY KEY,
  sku_id BIGINT, event_type ENUM('RESERVE_DEBIT','EXPIRE_CREDIT','CANCEL_CREDIT','ADJUSTMENT'),
  qty_delta INT, hold_id BIGINT NULL, idem_key CHAR(36) NULL,
  reason VARCHAR(100), actor VARCHAR(50), trace_id VARCHAR(64) NULL,
  created_at DATETIME NOT NULL,
  UNIQUE KEY uq_once_reserve(event_type, hold_id),      -- 같은 hold에 예약차감 1회만
  KEY(sku_id, created_at)
);

3) T1 전체 SQL(핵심만) — “전광판 & 영수증”이 같이 움직이는 모습
START TRANSACTION;

-- 1) 멱등성 등록 (같은 요청 한 번만)
INSERT INTO idempotency(user_id, idem_key, request_hash, status, created_at, updated_at)
VALUES(:uid, :idem, :hash, 'IN_PROGRESS', NOW(), NOW())
ON DUPLICATE KEY UPDATE idem_key = idem_key;

-- 이미 있음? → 기존 상태/응답 확인 후 종료(여기서는 생략)

-- 2) 동시중복 방지 깃발
INSERT INTO user_active_hold(sale_id, user_id, sku_id, hold_id, expire_at)
VALUES(:sale_id, :uid, :sku, NULL, '1970-01-01')
ON DUPLICATE KEY UPDATE sale_id = sale_id;  -- 있으면 거절 처리

-- 3) 전광판: 재고 조건부 한 방 감소
UPDATE inventory_counter
SET available = available - :qty
WHERE sku_id = :sku AND available >= :qty;

-- 영향행=0 → 재고 부족 → 깃발 제거 후 롤백/종료

-- 4) 예약 생성(HOLD + TTL)
INSERT INTO reservation_hold
(hold_id, sale_id, sku_id, user_id, qty, status, expire_at, created_at)
VALUES(:hold, :sale_id, :sku, :uid, :qty, 'HOLD', NOW()+INTERVAL 5 MINUTE, NOW());

UPDATE user_active_hold
SET hold_id=:hold, expire_at=NOW()+INTERVAL 5 MINUTE
WHERE sale_id=:sale_id AND user_id=:uid;

-- 5) 영수증: 이번 변화 기록(불변 INSERT, 음수 delta)
INSERT INTO inventory_ledger
(ledger_id, sku_id, event_type, qty_delta, hold_id, idem_key,
 reason, actor, trace_id, created_at)
VALUES
(:ledger, :sku, 'RESERVE_DEBIT', -:qty, :hold, :idem,
 'reserve', 'system', :trace_id, NOW());

COMMIT;


3) 전광판 숫자를 조건부 단일 UPDATE로 “가능하면 줄이고, 아니면 실패”

5) 같은 트랜잭션에서 영수증 한 장(INSERT) 남겨 “왜/얼마나 줄었는지” 기록

4) 한 줄로 다시 기억하기

재고 줄일 땐 전광판 숫자(Inventory Counter)를 조건부 한 방 UPDATE로 줄이고,
동시에 영수증(Inventory Ledger)을 INSERT해서 증거를 남긴다.
이 둘은 같은 트랜잭션에서 함께 성공/실패한다.