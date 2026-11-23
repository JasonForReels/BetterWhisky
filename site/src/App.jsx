import useScrollScenes from './useScrollScenes.js'

const REPO = 'https://github.com/JasonForReels/BetterWhisky'

const statement =
  'Paste a GitHub link. Press Play. BetterWhisky finds the right release, reads the install steps, keeps the game version the mod needs, and starts it through Steam so you stay signed in.'

const showcase = [
  {
    eyebrow: 'Library',
    title: 'Every mod gets its own card.',
    body: 'The regular game and each modded version sit side by side. Each mod lives in an instant APFS clone of the game, so it takes no extra space until Steam changes the original.',
    img: '/images/library.png',
    alt: 'BetterWhisky Library with Among Us, Town of Us: Mira and Steam',
  },
  {
    eyebrow: 'Mod settings',
    title: 'Switch mods with a toggle.',
    body: 'Built-in presets for Town of Us: Mira and The Other Roles, or any GitHub repo. Dependencies like Reactor and MiraAPI, and runtimes like .NET and Visual C++, come along automatically.',
    img: '/images/mod-settings.png',
    alt: 'Mod settings for Among Us',
  },
  {
    eyebrow: 'Loading',
    title: 'A loading screen that tells the truth.',
    body: 'Each stage is read from the log it writes: Steam signing in, Steam starting the game, the mod loading with a plugin count, the game opening.',
    img: '/images/loading.png',
    alt: 'Loading screen for a modded start',
  },
]

const features = [
  ['Mods update themselves', 'New releases install when they support the current game. A release for a different game version is refused with a clear reason.'],
  ['Plays through Steam', 'Games like Among Us only sign you in when Steam starts them. BetterWhisky sets Steam up once.'],
  ['Each mod keeps its version', 'When Steam updates the game, the modded card keeps working on the old one until the mod catches up.'],
  ['Pre-compiled on your Mac', 'Mod code is compiled ahead of time with crossgen2, and Steam warms up in the background.'],
]

const steps = ['Play', 'Steam', 'Launch script', 'BepInEx', 'Game']

export default function App() {
  useScrollScenes()
  const words = statement.split(' ')

  return (
    <>
      <nav className="nav">
        <span className="brand">BetterWhisky</span>
        <div className="nav-links">
          <a href="#showcase">Overview</a>
          <a href="#speed">Speed</a>
          <a href="#build">Build</a>
          <a className="nav-cta" href={REPO}>GitHub</a>
        </div>
      </nav>

      {/* 1. Hero: headline lifts away while the app window tilts up and fills the screen */}
      <section className="hero" data-scene>
        <div className="sticky">
          <div className="hero-copy">
            <p className="eyebrow">BetterWhisky for Mac</p>
            <h1>Whisky,<br />with one-click mods.</h1>
            <div className="ctas">
              <a className="btn" href="#build">Build for macOS</a>
              <a className="link" href="#showcase">See how it works ›</a>
            </div>
          </div>
          <div className="hero-device">
            <img src="/images/library.png" alt="BetterWhisky Library" />
          </div>
        </div>
      </section>

      {/* 2. Statement: words light up as you scroll */}
      <section className="statement" data-scene>
        <div className="sticky center">
          <p>
            {words.map((w, i) => (
              <span key={i} style={{ '--i': i / words.length }}>{w} </span>
            ))}
          </p>
        </div>
      </section>

      {/* 3. Pinned showcase: text steps through, screenshot crossfades */}
      <section id="showcase" className="showcase" data-scene data-steps={showcase.length}>
        <div className="sticky">
          <div className="showcase-grid">
            <div className="showcase-text">
              {showcase.map((s, i) => (
                <article key={s.title} data-i={i}>
                  <p className="eyebrow">{s.eyebrow}</p>
                  <h2>{s.title}</h2>
                  <p>{s.body}</p>
                </article>
              ))}
              <div className="dots">{showcase.map((s, i) => <i key={s.title} data-i={i} />)}</div>
            </div>
            <div className="showcase-stage">
              {showcase.map((s, i) => <img key={s.img} data-i={i} src={s.img} alt={s.alt} />)}
            </div>
          </div>
        </div>
      </section>

      {/* 4. Speed: big numbers */}
      <section id="speed" className="speed">
        <p className="eyebrow" data-reveal>Faster modded starts</p>
        <h2 className="huge" data-reveal>From 3½ minutes<br />to under 2.</h2>
        <div className="bars" data-reveal>
          <div className="bar before"><span>Before</span><b>~3.5 min</b></div>
          <div className="bar after"><span>BetterWhisky</span><b>&lt; 2 min</b></div>
        </div>
        <div className="stats">
          <div data-reveal><b><span data-count="4.9">0</span> GB</b><span>total memory, modded Among Us + Steam on an 8 GB Mac</span></div>
          <div data-reveal style={{ '--d': '120ms' }}><b><span data-count="480">0</span> MB</b><span>one-time Wine runtime download</span></div>
          <div data-reveal style={{ '--d': '240ms' }}><b><span data-count="1">0</span> click</b><span>to install a mod from GitHub</span></div>
        </div>
      </section>

      {/* 5. Flow: a line draws through the launch pipeline */}
      <section className="flow-scene" data-scene>
        <div className="sticky center">
          <p className="eyebrow">How a modded start works</p>
          <ol className="flow">
            {steps.map((s, i) => <li key={s} style={{ '--i': i / (steps.length - 1) }}><i />{s}</li>)}
          </ol>
        </div>
      </section>

      {/* 6. Feature grid */}
      <section className="features">
        <h2 className="huge" data-reveal>Everything else,<br />handled.</h2>
        <div className="grid">
          {features.map(([t, b], i) => (
            <article className="card" key={t} data-reveal style={{ '--d': `${(i % 2) * 120}ms` }}>
              <h3>{t}</h3>
              <p>{b}</p>
            </article>
          ))}
        </div>
      </section>

      {/* 7. Build */}
      <section id="build" className="build">
        <h2 className="huge" data-reveal>Build it tonight.</h2>
        <p className="sub" data-reveal>No signed releases yet. Apple Silicon, macOS Sequoia 15 or later.</p>
        <pre data-reveal><code>{`git clone ${REPO}.git
cd BetterWhisky
brew install swiftlint
xcodebuild -project Whisky.xcodeproj -scheme Whisky -configuration Release build`}</code></pre>
        <div className="ctas" data-reveal>
          <a className="btn" href={REPO}>View on GitHub</a>
        </div>
      </section>

      <footer>
        <p>
          BetterWhisky is a fork of <a href="https://github.com/frankea/Whisky">frankea/Whisky</a>,
          which continues <a href="https://github.com/whisky-app/whisky">Whisky</a> by Isaac
          Marovitz. Not affiliated with either project. GPL v3.
        </p>
        <p>
          <a href={REPO}>Source</a> · <a href={`${REPO}/issues`}>Issues</a> ·{' '}
          <a href={`${REPO}/blob/main/CHANGELOG.md`}>Changelog</a>
        </p>
      </footer>
    </>
  )
}
