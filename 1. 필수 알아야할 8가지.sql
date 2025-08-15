무엇을 꼭 알아야 하나(핵심 8개)

재고 초과주문 방지의 DB 해법

원자적 조건 감소: available >= qty 조건으로 단일 UPDATE 후 ROW_COUNT()=1 확인.

(예) UPDATE inventory_counter SET available = available - :q WHERE sku_id=:s AND available >= :q;

예약(hold)→확정(commit)→만료 복원(rollback) 흐름

reservation_hold(hold_id, sku_id, user_id, qty, expire_at, status)

만료 스캐너(주기 작업)로 expire_at 지난 예약을 가용 재고로 복구.

멱등성(Idempotency)

idempotency(user_id, idem_key UNIQUE)에 요청/응답 스냅샷 저장 → 중복요청 한 번만 처리.

락/동시성 전략

행 단일 카운터 핫스팟 → 조건부 UPDATE(락 경합 최소) + 실패 시 즉시 실패 반환.

필요 시 SKU별 샤딩 카운터(예: counter_0..N) 후 합산(읽기 전용 경로).

읽기/쓰기 분리(CQRS)

쓰기(재고·주문)는 주 DB(강한 일관성),

조회는 리플리카/캐시(재고 숫자는 참고용, 확정은 쓰기 경로에서만).

파티셔닝/인덱싱

원장/이벤트/로그는 시간 파티션, 재고·예약은 SKU PK/UK로 단건 조회 최적화.

고가용성/복구 시나리오

Aurora/MySQL/PG 리더-리플리카 전환, RPO/RTO 목표, 쓰기 재시도 정책(에러 분류).

관측/운영

지표: 재고 감소 성공률, 예약 만료율, p99 지연, 슬로우쿼리, 리플리카 래그.

감사 추적: 주문/재고 상태전이 불변 원장 테이블.

알면 가산점(선택)

트랜잭션 아웃박스 + CDC(이중쓰기 문제 해결).

Redis Lua로 원자적 토큰 POP(소스오브트루스는 DB 유지).

SKU별 단일 파티션 큐 직렬화(공정성↑, 지연 관리 필요).

1인 1개 제한을 **UNIQUE(user_id, sku_id, sale_id)**로 강제.

60초 답변 스크립트(그대로 말해도 됨)

“DBA 관점에선 초과 주문을 원자적 조건 UPDATE로 막습니다. available >= qty 조건이 충족될 때만 감소시키고, 성공 시에만 예약 레코드를 만들어요. 중복 요청은 Idempotency-Key UNIQUE로 1회 처리 보장합니다. 읽기 경로는 리플리카/캐시로 분리해 DB를 보호하고, 원장 테이블에 모든 상태 전이를 남겨 감사성과 복구성을 확보합니다. 파티셔닝은 원장·로그는 시간 기준, 재고·예약은 SKU 기준으로 최적화합니다. 장애 시에는 리더 전환과 재시도로 복구하고, 아웃박스를 써서 주문 이벤트 유실을 방지합니다.”

초미니 스키마/쿼리 예시(면접 화이트보드용)
-- 재고 카운터
CREATE TABLE inventory_counter (
  sku_id BIGINT PRIMARY KEY,
  available INT NOT NULL
);

-- 예약
CREATE TABLE reservation_hold (
  hold_id BIGINT PRIMARY KEY,
  sku_id BIGINT NOT NULL,
  user_id BIGINT NOT NULL,
  qty INT NOT NULL,
  status ENUM('HOLD','COMMITTED','EXPIRED','CANCELLED') NOT NULL,
  expire_at DATETIME NOT NULL,
  KEY (sku_id), KEY (expire_at)
);

-- 멱등성
CREATE TABLE idempotency (
  user_id BIGINT NOT NULL,
  idem_key CHAR(36) NOT NULL,
  response_json JSON,
  created_at DATETIME NOT NULL,
  UNIQUE KEY uq(user_id, idem_key)
);

-- 원자적 감소
UPDATE inventory_counter
SET available = available - :qty
WHERE sku_id = :sku AND available >= :qty;
-- ROW_COUNT() = 1 이어야 성공

자주 나오는 함정 질문 대응

“SERIALIZABLE 쓰면 되나요?”
→ 가능하지만 비용이 큼. 조건부 UPDATE + 고유 제약이 고부하에 더 적합.

“MySQL GET_LOCK으로 분산락?”
→ 트랜잭션 일관성/장애 복구 측면에서 취약. 데이터 무결성은 제약/조건부 갱신으로.

“Redis만으로 재고 관리?”
→ 속도는 좋지만 소스오브트루스는 DB. 캐시 장애/데이터 유실 대비가 필요.

“리플리카에서 재고 읽고 결정?”
→ 금지(래그로 초과주문 위험). 결정은 반드시 주 DB 트랜잭션에서.

면접 준비 체크리스트(한 장)

행 단위 핫스팟 완화: 조건부 UPDATE, 샤딩 카운터, 토큰 방식 비교 포인트.

예약 TTL 만료 처리와 재고 복원 절차.

멱등성 키 스키마/수명 관리.

파티션 전략과 인덱스 설계 근거.

리플리카 래그가 의사결정에 미치는 영향과 회피법.

아웃박스/CDC로 “유실 0” 보장 논리.

필수 운영 지표/알람 세트.