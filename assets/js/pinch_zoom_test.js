import {describe, it} from "node:test"
import assert from "node:assert/strict"
import {
  clampScale,
  touchDistance,
  touchMidpoint,
  clientToImgLocal,
  imgLocalMidpoint,
  focalTranslate,
  shouldDoubleTapReset,
  photoIdentityFromImg
} from "./pinch_zoom.js"

describe("clampScale", () => {
  it("clamps to [1, 5]", () => {
    assert.equal(clampScale(0.5), 1)
    assert.equal(clampScale(3), 3)
    assert.equal(clampScale(9), 5)
  })
})

describe("touch geometry", () => {
  it("distance and midpoint", () => {
    const a = {clientX: 0, clientY: 0}
    const b = {clientX: 30, clientY: 40}
    assert.equal(touchDistance(a, b), 50)
    assert.deepEqual(touchMidpoint(a, b), {x: 15, y: 20})
  })

  it("converts viewport midpoint into img-local coords", () => {
    // flex-centered img: layout origin at (40, 60), current translate (10, 5)
    const rect = {left: 50, top: 65}
    const tx = 10
    const ty = 5
    assert.deepEqual(clientToImgLocal({x: 100, y: 80}, rect, tx, ty), {x: 60, y: 20})

    const a = {clientX: 90, clientY: 70}
    const b = {clientX: 110, clientY: 90}
    assert.deepEqual(imgLocalMidpoint(a, b, rect, tx, ty), {x: 60, y: 20})
  })
})

describe("focalTranslate", () => {
  it("keeps the focal content point under the midpoint when scaling", () => {
    // start: identity translate, mid at (100, 80), scale 1 → 2
    const start = {scale: 1, tx: 0, ty: 0, mid: {x: 100, y: 80}}
    const mid = {x: 100, y: 80}
    const {tx, ty} = focalTranslate(start, mid, 2)
    // content under mid is (100, 80); after scale 2 from origin 0,0 need tx/ty so it stays put
    assert.equal(tx + 100 * 2, 100)
    assert.equal(ty + 80 * 2, 80)
    assert.equal(tx, -100)
    assert.equal(ty, -80)
  })

  it("tracks a moving midpoint (pan while pinching)", () => {
    const start = {scale: 1, tx: 0, ty: 0, mid: {x: 100, y: 100}}
    const mid = {x: 150, y: 120}
    const {tx, ty} = focalTranslate(start, mid, 2)
    assert.equal(tx + 100 * 2, 150)
    assert.equal(ty + 100 * 2, 120)
  })

  it("does not jump when layout origin is offset from viewport (0,0)", () => {
    // Same pinch as first test, but mids expressed relative to a flex-centered layout
    // origin at (40, 60) — i.e. after clientToImgLocal conversion.
    const start = {scale: 1, tx: 0, ty: 0, mid: {x: 100, y: 80}}
    const mid = {x: 100, y: 80}
    const {tx, ty} = focalTranslate(start, mid, 2)
    assert.equal(tx, -100)
    assert.equal(ty, -80)
    // If raw client mids (140, 140) were used instead of img-local (100, 80),
    // tx would be -140 and the image would jump by -origin*(1-ratio).
  })
})

describe("shouldDoubleTapReset", () => {
  it("does not reset while fingers remain", () => {
    const r = shouldDoubleTapReset({
      multiTouch: false,
      singleFinger: true,
      touchesRemaining: 1,
      now: 1000,
      lastTap: 900
    })
    assert.equal(r.reset, false)
  })

  it("ignores pinch end as a double-tap", () => {
    const first = shouldDoubleTapReset({
      multiTouch: true,
      singleFinger: false,
      touchesRemaining: 0,
      now: 1000,
      lastTap: 0
    })
    assert.equal(first.reset, false)
    assert.equal(first.clearMulti, true)
    assert.equal(first.clearSingle, true)
    assert.equal(first.lastTap, 0)

    // second empty touchend after multi cleared must not seed lastTap
    const second = shouldDoubleTapReset({
      multiTouch: false,
      singleFinger: false,
      touchesRemaining: 0,
      now: 1050,
      lastTap: 0
    })
    assert.equal(second.reset, false)
    assert.equal(second.lastTap, 0)
    assert.equal(second.clearSingle, true)
  })

  it("does not reset from a single tap within 300ms after pinch", () => {
    shouldDoubleTapReset({
      multiTouch: true,
      singleFinger: false,
      touchesRemaining: 0,
      now: 1000,
      lastTap: 0
    })
    const stray = shouldDoubleTapReset({
      multiTouch: false,
      singleFinger: false,
      touchesRemaining: 0,
      now: 1010,
      lastTap: 0
    })
    assert.equal(stray.lastTap, 0)

    const realTap = shouldDoubleTapReset({
      multiTouch: false,
      singleFinger: true,
      touchesRemaining: 0,
      now: 1200,
      lastTap: stray.lastTap
    })
    assert.equal(realTap.reset, false)
    assert.equal(realTap.lastTap, 1200)
  })

  it("resets on real single-finger double-tap", () => {
    const t1 = shouldDoubleTapReset({
      multiTouch: false,
      singleFinger: true,
      touchesRemaining: 0,
      now: 1000,
      lastTap: 0
    })
    assert.equal(t1.reset, false)
    assert.equal(t1.lastTap, 1000)
    assert.equal(t1.clearSingle, true)

    const t2 = shouldDoubleTapReset({
      multiTouch: false,
      singleFinger: true,
      touchesRemaining: 0,
      now: 1200,
      lastTap: t1.lastTap
    })
    assert.equal(t2.reset, true)
  })

  it("does not reset when taps are far apart", () => {
    const r = shouldDoubleTapReset({
      multiTouch: false,
      singleFinger: true,
      touchesRemaining: 0,
      now: 2000,
      lastTap: 1000
    })
    assert.equal(r.reset, false)
    assert.equal(r.lastTap, 2000)
  })

  it("clears sticky multiTouch on interrupt (touchcancel as multi end)", () => {
    const cancelled = shouldDoubleTapReset({
      multiTouch: true,
      singleFinger: false,
      touchesRemaining: 0,
      now: 1000,
      lastTap: 500
    })
    assert.equal(cancelled.reset, false)
    assert.equal(cancelled.clearMulti, true)
    assert.equal(cancelled.clearSingle, true)
    assert.equal(cancelled.lastTap, 0)

    const nextTap = shouldDoubleTapReset({
      multiTouch: false,
      singleFinger: true,
      touchesRemaining: 0,
      now: 1500,
      lastTap: cancelled.lastTap
    })
    assert.equal(nextTap.reset, false)
    assert.equal(nextTap.lastTap, 1500)
  })
})

describe("photoIdentityFromImg", () => {
  it("reads src for identity", () => {
    assert.equal(photoIdentityFromImg(null), null)
    assert.equal(
      photoIdentityFromImg({getAttribute: (k) => (k === "src" ? "/photos/a.jpg" : null)}),
      "/photos/a.jpg"
    )
  })
})
