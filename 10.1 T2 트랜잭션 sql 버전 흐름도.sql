-- 입력: :user_id, :idem_key(PG거래ID), :hold_id

/* 1) 멱등성 체크 */
SELECT response_json
FROM idempotency
WHERE user_id = :user_id AND idem_key = :idem_key
LIMIT 1;

/* 이미 처리됐다면 여기서 response_json 반환 후 끝 */

/* 2) 멱등 슬롯 선점(동시 중복 진입 차단) */
INSERT INTO idempotency(user_id, idem_key, request_hash, status)
VALUES(:user_id, :idem_key, :request_hash, 'IN_PROGRESS');
-- UNIQUE(user_id, idem_key)로 보호 (중복 요청 1회 처리 보장)

/* 3) 본 처리 트랜잭션 시작 */
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
START TRANSACTION;

/* 3-1) HOLD 유효성 + 직렬화 진입 */
SELECT sku_id, user_id, qty, status, expire_at
FROM reservation_hold
WHERE hold_id = :hold_id
FOR UPDATE;

/* 유효성 검사 */
-- if row not found → ROLLBACK; (HOLD_NOT_FOUND)
-- if status <> 'HOLD' or expire_at <= NOW() → ROLLBACK; (HOLD_INVALID)

/* 3-2) (옵션) 재고 감소가 확정 시점인 모델일 때: 초과주문 방지 */
-- UPDATE inventory_counter
--   SET available = available - :qty
-- WHERE sku_id = :sku_id AND available >= :qty;
-- IF ROW_COUNT() = 0 THEN ROLLBACK; (OUT_OF_STOCK) END IF;

/* 3-3) 주문 생성 */
SET @new_order_id = /* 생성 로직 or AUTO_INCREMENT */;
INSERT INTO orders(order_id, user_id, status, total_qty, hold_id)
VALUES(@new_order_id, :user_id, 'CONFIRMED', :qty, :hold_id);

INSERT INTO order_items(order_id, sku_id, qty)
VALUES(@new_order_id, :sku_id, :qty);

/* 3-4) HOLD 확정(같은 트랜잭션) */
UPDATE reservation_hold
SET status = 'COMMITTED'
WHERE hold_id = :hold_id AND status = 'HOLD';

/* 3-5) 주문 원장 + 아웃박스(커밋과 동일 운명) */
INSERT INTO order_ledger(order_id, event_type, payload)
VALUES(@new_order_id, 'ORDER_CONFIRMED',
       JSON_OBJECT('hold_id', :hold_id, 'sku_id', :sku_id, 'qty', :qty));

INSERT INTO event_outbox(aggregate_type, aggregate_id, event_type, payload)
VALUES('Order', @new_order_id, 'OrderConfirmed',
       JSON_OBJECT('order_id', @new_order_id, 'user_id', :user_id,
                   'sku_id', :sku_id, 'qty', :qty));

/* 4) 커밋 */
COMMIT;

/* 5) 멱등 응답 스냅샷 저장(이후 중복 요청 즉시 반환) */
UPDATE idempotency
SET status = 'SUCCEEDED',
    response_json = JSON_OBJECT('order_id', @new_order_id, 'status', 'CONFIRMED')
WHERE user_id = :user_id AND idem_key = :idem_key;
