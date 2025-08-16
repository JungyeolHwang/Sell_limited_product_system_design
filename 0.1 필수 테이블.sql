-- 1) 멱등성: 같은 요청(사용자, 키) 한 번만 처리
CREATE TABLE idempotency (
  user_id       BIGINT       NOT NULL,
  idem_key      CHAR(36)     NOT NULL,         -- 클라이언트가 준 UUID 등
  request_hash  BINARY(32)   NOT NULL,         -- method+path+body 해시(SHA-256)
  status        ENUM('IN_PROGRESS','SUCCEEDED','FAILED') NOT NULL,
  response_json JSON         NULL,             -- 성공 시 응답 스냅샷
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_user_key (user_id, idem_key),
  KEY           k_created    (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 2) 1인 동시중복 예약 방지(가벼운 깃발 테이블)
CREATE TABLE user_active_hold (
  sale_id    BIGINT     NOT NULL,
  user_id    BIGINT     NOT NULL,
  sku_id     BIGINT     NOT NULL,
  hold_id    BIGINT     NULL,      -- 예약 생성 후 연결
  expire_at  DATETIME   NULL,
  PRIMARY KEY (sale_id, user_id),
  KEY         k_user        (user_id),
  KEY         k_expire_at   (expire_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 3) 전광판: 현재 가용 재고(조건부 단일 UPDATE 대상으로 딱 한 행)
CREATE TABLE inventory_counter (
  sku_id     BIGINT   NOT NULL,
  available  INT      NOT NULL CHECK (available >= 0),
  PRIMARY KEY (sku_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 4) 예약(HOLD) 레코드: 결제 전 임시 점유 + TTL
CREATE TABLE reservation_hold (
  hold_id     BIGINT   NOT NULL,  -- 앱에서 생성(snowflake 등) or AUTO_INCREMENT 사용 가능
  sale_id     BIGINT   NOT NULL,
  sku_id      BIGINT   NOT NULL,
  user_id     BIGINT   NOT NULL,
  qty         INT      NOT NULL,
  status      ENUM('HOLD','COMMITTED','EXPIRED','CANCELLED') NOT NULL,
  expire_at   DATETIME NOT NULL,
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (hold_id),
  KEY         k_expire_at (expire_at),
  KEY         k_user_sku_status_exp (user_id, sku_id, status, expire_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 5) 영수증(불변 원장): 재고 변화 히스토리 (INSERT 전용)
CREATE TABLE inventory_ledger (
  ledger_id    BIGINT    NOT NULL AUTO_INCREMENT,
  sku_id       BIGINT    NOT NULL,
  event_type   ENUM('RESERVE_DEBIT','EXPIRE_CREDIT','CANCEL_CREDIT','ADJUSTMENT') NOT NULL,
  qty_delta    INT       NOT NULL,     -- 차감은 음수(-), 복원은 양수(+)
  hold_id      BIGINT    NULL,
  order_id     BIGINT    NULL,
  idem_key     CHAR(36)  NULL,         -- 추적용
  reason       VARCHAR(100) NOT NULL,  -- 'reserve','expire','cancel','manual_adjust' 등
  actor        VARCHAR(50)  NOT NULL,  -- 'system','admin:uid=...' 등
  trace_id     VARCHAR(64)  NULL,
  created_at   DATETIME   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (ledger_id),
  UNIQUE KEY uq_reserve_once (event_type, hold_id),  -- 같은 hold에 같은 타입 1회만
  KEY         k_sku_time (sku_id, created_at),
  KEY         k_hold (hold_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 6) 아웃박스: 외부 전파용 이벤트 대기열(커밋과 원자적으로 기록)
CREATE TABLE event_outbox (
  event_id        BIGINT      NOT NULL AUTO_INCREMENT,
  aggregate_type  VARCHAR(50) NOT NULL,   -- e.g. 'InventoryReservation'
  aggregate_id    BIGINT      NOT NULL,   -- e.g. hold_id
  event_type      VARCHAR(50) NOT NULL,   -- e.g. 'ReservationCreated'
  payload         JSON        NOT NULL,   -- 전송할 내용(필수 필드만)
  status          ENUM('PENDING','IN_PROGRESS','SENT','FAILED') NOT NULL DEFAULT 'PENDING',
  created_at      DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  sent_at         DATETIME    NULL,
  PRIMARY KEY (event_id),
  UNIQUE KEY uq_aggregate_event (aggregate_type, aggregate_id, event_type),  -- 같은 aggregate에 같은 이벤트 1회만
  KEY             k_status_time (status, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- A) 주문 헤더
CREATE TABLE orders (
  order_id   BIGINT      NOT NULL,     -- 애플/서버에서 생성 or AUTO_INCREMENT
  user_id    BIGINT      NOT NULL,
  status     ENUM('CONFIRMED','CANCELLED') NOT NULL,
  total_qty  INT         NOT NULL,
  hold_id    BIGINT      NOT NULL,     -- 어떤 HOLD를 확정했는지 추적(선택 아님: 강추)
  created_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (order_id),
  UNIQUE KEY uq_hold_once (hold_id),   -- 같은 HOLD로 주문 1회만 생성(이중 확정 방지)
  KEY k_user_time (user_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- B) 주문 품목
CREATE TABLE order_items (
  order_id BIGINT NOT NULL,
  sku_id   BIGINT NOT NULL,
  qty      INT    NOT NULL,
  PRIMARY KEY (order_id, sku_id),
  KEY k_sku (sku_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- (권장) C) 주문 원장(불변 감사 로그) - 재고 원장과 역할 분리
CREATE TABLE order_ledger (
  ledger_id   BIGINT NOT NULL AUTO_INCREMENT,
  order_id    BIGINT NOT NULL,
  event_type  ENUM('ORDER_CONFIRMED','ORDER_CANCELLED') NOT NULL,
  payload     JSON   NULL,
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (ledger_id),
  KEY k_order (order_id),
  KEY k_type_time (event_type, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
