import {describe, it} from "node:test"
import assert from "node:assert/strict"
import {
  clampScale,
  touchDistance,
  touchMidpoint,
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
})

describe("shouldDoubleTapReset", () => {
  it("does not reset while fingers remain", () => {
    const r = shouldDoubleTapReset({multiTouch: false, touchesRemaining: 1, now: 1000, lastTap: 900})
    assert.equal(r.reset, false)
  })

  it("ignores pinch end as a double-tap", () => {
    const first = shouldDoubleTapReset({multiTouch: true, touchesRemaining: 0, now: 1000, lastTap: 0})
    assert.equal(first.reset, false)
    assert.equal(first.clearMulti, true)
    assert.equal(first.lastTap, 0)

    // second finger already covered by multiTouch; a rapid follow-up must not reset
    const second = shouldDoubleTapReset({
      multiTouch: true,
      touchesRemaining: 0,
      now: 1050,
      lastTap: 1000
    })
    assert.equal(second.reset, false)
    assert.equal(second.lastTap, 0)
  })

  it("resets on real single-finger double-tap", () => {
    const t1 = shouldDoubleTapReset({multiTouch: false, touchesRemaining: 0, now: 1000, lastTap: 0})
    assert.equal(t1.reset, false)
    assert.equal(t1.lastTap, 1000)

    const t2 = shouldDoubleTapReset({
      multiTouch: false,
      touchesRemaining: 0,
      now: 1200,
      lastTap: t1.lastTap
    })
    assert.equal(t2.reset, true)
  })

  it("does not reset when taps are far apart", () => {
    const r = shouldDoubleTapReset({multiTouch: false, touchesRemaining: 0, now: 2000, lastTap: 1000})
    assert.equal(r.reset, false)
    assert.equal(r.lastTap, 2000)
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
