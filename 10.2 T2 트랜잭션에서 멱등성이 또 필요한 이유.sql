1. 중복이 오는 이유

PG(결제사)는 결제가 성공했어도 네트워크 끊김이나 응답 지연이 있으면 “성공” 메시지를 또 보냅니다.

사용자가 같은 결제건으로 /confirm을 두 번 호출할 수도 있어요.

2. 중복 방지 핵심 장치 → 멱등성 테이블
CREATE TABLE idempotency (
  user_id BIGINT NOT NULL,
  idem_key CHAR(36) NOT NULL,   -- PG 거래 ID 등
  response_json JSON,
  UNIQUE KEY uq_user_key (user_id, idem_key)
);


(user_id, idem_key)를 UNIQUE로 만들어서,
같은 결제건이 오면 DB 차원에서 한 번만 통과시키게 합니다.

3. 동작 흐름
1) /confirm 호출 시
   - SELECT 해서 idem_key가 있으면 → 저장된 응답 그대로 반환 (중복 처리 X)
   - 없으면 → INSERT (status='IN_PROGRESS')로 선점

2) 선점에 성공한 요청만
   - HOLD 유효성 검사 (만료, 상태 확인)
   - 주문 생성 + HOLD 확정
   - 원장/아웃박스 기록

3) COMMIT 후
   - idempotency.response_json에 주문 결과 저장

4) 나중에 같은 idem_key로 호출이 오면
   - SELECT로 response_json 찾아서 바로 반환


→ 결과: PG가 웹훅을 몇 번 보내든, 사용자가 몇 번 눌러도 주문은 딱 1건만 생성.

4. 한 줄 비유

마트 계산대에서:

첫 손님: “이 결제건 처리할게” 하고 계산 시작 → 결제 완료 + 영수증 기록.

두 번째 손님(같은 결제건): 직원이 영수증 보고 “이미 처리됐어요” 하고 그대로 보여줌.





시나리오 A: PG가 같은 결제 성공 웹훅을 2번 보냄
[첫 번째 웹훅]
/confirm 도착
  ├─ idempotency SELECT → 없음
  ├─ idempotency INSERT(IN_PROGRESS)  ← UNIQUE(user_id, idem_key)
  ├─ (HOLD 검사) reservation_hold FOR UPDATE  ← 만료/상태 확인
  ├─ 주문 생성 + HOLD=COMMITTED (같은 트랜잭션)
  ├─ 원장/아웃박스 기록
  └─ COMMIT → idempotency.response_json 저장

[두 번째 웹훅]
/confirm 도착
  └─ idempotency SELECT → response_json 발견 → 그 응답 그대로 반환(끝)


결과: 주문은 1건만 생성, 두 번째는 저장된 응답 재사용.

시나리오 B: 사용자가 버튼을 두 번 눌러 /confirm을 연속 호출
[첫 호출]   SELECT 없음 → INSERT 선점 → 처리/커밋 → response_json 저장
[두 번째]   SELECT로 response_json 즉시 반환 (주문 추가 생성 없음)


결과: 중복 호출도 안전.

시나리오 C: 두 서버가 동시에 같은 결제건을 처리(레이스)
서버A: idempotency INSERT → 성공(선점)
서버B: idempotency INSERT → UNIQUE 충돌 (이미 선점됨)
서버B: idempotency SELECT 재조회 → A가 저장한 response_json 반환


결과: DB가 한 명만 통과, 나머지는 응답 재사용.

시나리오 D: 주문은 커밋됐는데 응답 직전에 서버 크래시
1) IN_PROGRESS 선점
2) 주문 생성/확정 + COMMIT 성공
3) 응답 직전 크래시 (클라에선 실패처럼 보임)
4) 재호출/재웹훅 → idempotency SELECT → 저장된 response_json 반환


결과: 중복 커밋 없이 같은 결과를 안전하게 재응답.

핵심 두 줄(SQL 요지)
-- (1) 선점: 없으면 내가 처리 시작 (동시중복 진입 컷)
INSERT INTO idempotency(user_id, idem_key, status) VALUES (:uid, :key, 'IN_PROGRESS');
-- UNIQUE(user_id, idem_key)

-- (2) 재사용: 이미 처리된 건 저장된 응답을 즉시 반환
SELECT response_json FROM idempotency WHERE user_id=:uid AND idem_key=:key;

왜 이게 안전한가 (한 줄씩)

중복 방지: UNIQUE 제약으로 “결제 1건 = 처리 1번”을 DB가 강제.

순서 꼬임/만료 방지: HOLD는 FOR UPDATE로 유효성 확인 후에만 확정.

초과주문 방지(옵션): 필요하면 inventory_counter를 조건부 UPDATE(available >= qty)로 감소.

후속 전파 보장: 확정 이벤트는 아웃박스에 같은 트랜잭션으로 기록(유실/유령 없음).

필요하면 위 흐름을 복붙 가능한 최종 SQL로 다시 한 장에 묶어줄게.