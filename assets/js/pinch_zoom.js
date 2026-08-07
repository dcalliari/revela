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
 * Convert a viewport/client point into the img layout box (transform-origin 0 0).
 * rect is getBoundingClientRect() under the current translate(tx,ty) scale.
 */
export function clientToImgLocal(client, rect, tx, ty) {
  return {
    x: client.x - rect.left + tx,
    y: client.y - rect.top + ty
  }
}

export function imgLocalMidpoint(a, b, rect, tx, ty) {
  return clientToImgLocal(touchMidpoint(a, b), rect, tx, ty)
}

/**
 * Focal-point zoom: keep the content under `mid` fixed while scale changes
 * from `startScale`→`newScale`, given the transform at pinch start.
 * Assumes CSS transform-origin is top-left (0 0) and mid is img-local.
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
 * Only gestures that began as one-finger may seed lastTap.
 */
export function shouldDoubleTapReset({
  multiTouch,
  singleFinger = true,
  touchesRemaining,
  now,
  lastTap,
  windowMs = 300
}) {
  if (touchesRemaining !== 0) {
    return {reset: false, lastTap, clearMulti: false, clearSingle: false}
  }
  if (multiTouch) {
    return {reset: false, lastTap: 0, clearMulti: true, clearSingle: true}
  }
  if (!singleFinger) {
    return {reset: false, lastTap: 0, clearMulti: false, clearSingle: true}
  }
  if (lastTap > 0 && now - lastTap < windowMs) {
    return {reset: true, lastTap: now, clearMulti: false, clearSingle: true}
  }
  return {reset: false, lastTap: now, clearMulti: false, clearSingle: true}
}

export function photoIdentityFromImg(img) {
  if (!img) return null
  return img.getAttribute("src") || img.getAttribute("data-photo-id") || null
}
