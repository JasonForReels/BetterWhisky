import { useEffect } from 'react'

// Scroll engine, no re-renders. On each frame it writes:
//  - [data-scene]: --p = 0..1 progress through the element's own scroll span
//    (start when its top hits the viewport top, end when its bottom hits the viewport bottom).
//    Used by tall sticky sections.
//  - [data-reveal]: adds .in once the element enters the viewport.
//  - [data-count]: counts the number up once revealed.
export default function useScrollScenes() {
  useEffect(() => {
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    const scenes = [...document.querySelectorAll('[data-scene]')]
    let raf = 0

    const update = () => {
      raf = 0
      const vh = window.innerHeight
      for (const el of scenes) {
        const r = el.getBoundingClientRect()
        const span = r.height - vh
        const p = span > 0 ? Math.min(1, Math.max(0, -r.top / span)) : r.top < vh ? 1 : 0
        el.style.setProperty('--p', reduce ? 1 : p.toFixed(4))
        // Optional discrete step for crossfading showcases
        const steps = Number(el.dataset.steps || 0)
        if (steps) {
          const i = Math.min(steps - 1, Math.floor(p * steps))
          if (el.dataset.active !== String(i)) el.dataset.active = String(i)
        }
      }
    }
    const onScroll = () => { if (!raf) raf = requestAnimationFrame(update) }

    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (!e.isIntersecting) continue
          e.target.classList.add('in')
          if (e.target.dataset.count) countUp(e.target, reduce)
          io.unobserve(e.target)
        }
      },
      { threshold: 0.2, rootMargin: '0px 0px -8% 0px' },
    )
    document.querySelectorAll('[data-reveal],[data-count]').forEach((el) => io.observe(el))

    update()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll)
    return () => {
      io.disconnect()
      cancelAnimationFrame(raf)
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
    }
  }, [])
}

function countUp(el, reduce) {
  const target = parseFloat(el.dataset.count)
  const decimals = (el.dataset.count.split('.')[1] || '').length
  if (reduce) { el.textContent = target.toFixed(decimals); return }
  const dur = 1400
  const t0 = performance.now()
  const tick = (t) => {
    const k = Math.min(1, (t - t0) / dur)
    const eased = 1 - Math.pow(1 - k, 4)
    el.textContent = (target * eased).toFixed(decimals)
    if (k < 1) requestAnimationFrame(tick)
  }
  requestAnimationFrame(tick)
}
