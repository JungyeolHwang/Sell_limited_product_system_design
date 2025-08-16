짧게 말하면, T3(만료 스캐너)는 “버려진 예약(HOLD)을 확실히 정리해서 재고를 되살리고, 원장·이벤트까지 일관되게 남기는 최후의 안전장치”예요. 없으면 재고가 새지 않고도 “묶여 죽는(dead stock)” 문제가 생깁니다.

왜 꼭 필요해?

결제/확정(T2)이 영원히 오지 않는 수많은 경우 처리

PG 웹훅 유실·지연, 네트워크 단절, 앱/서버 크래시, 사용자가 결제 창을 닫음, 카드 실패…
→ HOLD는 살아있는데 아무도 확정하지 않으면 재고가 계속 묶입니다. T3가 expire_at 지난 HOLD를 찾아서 EXPIRED로 전이하고, 묶인 수량을 available로 되돌립니다.

“재고 일관성”의 최종 보루

우리 시스템의 재고 흐름은 “예약(HOLD) → (성공 시) 확정(COMMITTED) / (실패·방치 시) 만료(EXPIRED)”라는 2갈래입니다.

T3는 이 중 “방치 시나리오”를 책임지고 재고 원장(ledger)·아웃박스(outbox)까지 함께 기록해 감사 추적/외부 전파를 보장합니다. (예: event_type='ReservationExpired', 원장에 EXPIRE_CREDIT(+qty) 적재)

고부하에서도 안전하고 예측 가능한 동작

배치로 “시간 순(expire_at ASC)” 처리 + 청크(LIMIT N)로 부하 제어

DB 시간을 기준으로 만료 판단(애플리케이션·클라이언트 시계치 skew 무시)

크래시 중간에도 멱등: 같은 HOLD에 같은 만료 처리/원장 이벤트는 1회만 들어가도록 제약을 둡니다(예: (event_type, hold_id) 유니크). 중간 실패해도 재시도에 안전합니다.

T2(확정)와의 경합을 깨끗하게 해소

T2는 /confirm에서 해당 HOLD를 SELECT ... FOR UPDATE로 잠그고 COMMITTED로 전이합니다.

T3는 만료 후보를 조회할 때 행 락 경합 회피를 씁니다:

“상태='HOLD' AND expire_at <= NOW()” 만 처리

가능하면 FOR UPDATE SKIP LOCKED(PG/MySQL8+)로 T2가 잡은 HOLD는 건너뜀

만료 전이/재고 복원/원장·아웃박스를 한 트랜잭션(T3) 안에서 처리
→ 동시에 달려도 “확정이 먼저 커밋되면 만료는 조건 미일치로 스킵”, “만료가 먼저 커밋되면 T2는 상태 검사에서 중단”이라 이중 확정/이중 복원이 논리적으로 차단됩니다.

성능·운영 상 이점

읽기/쓰기 경로를 건드리지 않고, 주기 작업으로 조용히 청소 → 트래픽 피크 때도 앞단 TPS에 영향 최소화

메트릭이 분명: “활성 HOLD 수”, “만료 처리율/지연”, “만료 후 재고 복원량”으로 이상 징후 감지 쉬움

안전한 T3 처리 패턴(의사코드)

주기적으로 다음을 반복(예: 매 100ms1s, 청크 5002000행):

BEGIN;

-- 1) 만료 대상 픽업(경합 회피)
SELECT hold_id, sku_id, qty
FROM reservation_hold
WHERE status='HOLD' AND expire_at <= NOW()
FOR UPDATE SKIP LOCKED     -- 가능 시(PSQL/MySQL8+), 아니면 좁은 인덱스로 빠르게 스캔
LIMIT :batch;

-- 2) 상태 전이 + 재고 복원 + 원장 + 아웃박스(같은 트랜잭션)
UPDATE reservation_hold
  SET status='EXPIRED'
WHERE hold_id IN (:picked_ids) AND status='HOLD';

UPDATE inventory_counter
  SET available = available + :sum(qty)  -- 또는 개별 SKU별로 누적 반영
WHERE sku_id = :sku;

INSERT INTO inventory_ledger(event_type, qty_delta, hold_id, reason, actor)
VALUES ('EXPIRE_CREDIT', +qty, hold_id, 'expire', 'system') ...;   -- 각 HOLD별 1행

INSERT INTO event_outbox(aggregate_type, aggregate_id, event_type, payload)
VALUES ('InventoryReservation', hold_id, 'ReservationExpired', payload_json) ...;

COMMIT;


제약/인덱스의 핵심:

reservation_hold(status, expire_at)/k_expire_at로 만료 스캔 가속

inventory_ledger에 (event_type, hold_id) UNIQUE → 중복 원장 방지

아웃박스는 상태 전이와 같은 커밋으로 적재(후속 퍼블리셔가 전송)

요약

T2는 “확정 경로”를, T3는 “청소·복원 경로”를 담당합니다.

현실 세계의 실패/방치 시나리오를 닫아 재고가 영구히 묶이지 않게 하고, 재고 수치·원장·이벤트를 원자적으로 맞춰 주는 역할이기 때문에 T3는 필수입니다.