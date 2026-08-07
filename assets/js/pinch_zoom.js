// Pure helpers for PinchZoom (focal-point scale + double-tap vs pinch-end).
// Kept separate so node --test can cover the math without a browser.

export function clampScale(scale, min = 1, max = 5) {
  return Math.min(Math.max(scale, min), max)
}

export function touchDistance(a, b) {
  return Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY)
}

export function touchMidpoint(a, b) {
  return {
    x: (a.clientX + b.clientX) / 2,
    y: (a.clientY + b.clientY) / 2
  }
}

/**
 * Focal-point zoom: keep the content under `mid` fixed while scale changes
 * from `startScale`→`newScale`, given the transform at pinch start.
 * Assumes CSS transform-origin is top-left (0 0).
 */
export function focalTranslate(start, mid, newScale) {
  const ratio = newScale / start.scale
  return {
    tx: mid.x - (start.mid.x - start.tx) * ratio,
    ty: mid.y - (start.mid.y - start.ty) * ratio
  }
}

/**
 * Decide whether a touchend (all fingers up) should reset via double-tap.
 * Pinch / multi-touch endings must not count as taps.
 */
export function shouldDoubleTapReset({multiTouch, touchesRemaining, now, lastTap, windowMs = 300}) {
  if (touchesRemaining !== 0) return {reset: false, lastTap, clearMulti: false}
  if (multiTouch) return {reset: false, lastTap: 0, clearMulti: true}
  if (lastTap > 0 && now - lastTap < windowMs) {
    return {reset: true, lastTap: now, clearMulti: false}
  }
  return {reset: false, lastTap: now, clearMulti: false}
}

export function photoIdentityFromImg(img) {
  if (!img) return null
  return img.getAttribute("src") || img.getAttribute("data-photo-id") || null
}
