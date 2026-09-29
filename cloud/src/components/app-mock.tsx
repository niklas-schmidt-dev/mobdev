const icons = [
  "from-sky-400 to-blue-600",
  "from-amber-300 to-orange-500",
  "from-emerald-300 to-green-600",
  "from-zinc-200 to-zinc-400",
  "from-rose-400 to-red-600",
  "from-violet-400 to-indigo-600",
  "from-lime-300 to-lime-500",
  "from-cyan-300 to-teal-500",
  "from-fuchsia-400 to-pink-600",
  "from-yellow-200 to-amber-400",
  "from-slate-500 to-slate-700",
  "from-orange-300 to-rose-500",
  "from-blue-300 to-indigo-500",
  "from-green-300 to-emerald-600",
  "from-red-300 to-rose-600",
  "from-teal-200 to-cyan-600",
];

/** A drawing of the Mobdev window, so the page never shows anyone's real phone. */
export function AppMock() {
  return (
    <div
      aria-hidden="true"
      className="relative mx-auto w-full max-w-5xl overflow-hidden rounded-[22px] border border-white/10 bg-[#1b1d1b] shadow-[0_40px_120px_-20px_rgba(0,0,0,0.8)]"
    >
      <div className="grid grid-cols-[180px_1fr] md:grid-cols-[200px_1fr_230px]">
        {/* Sidebar */}
        <div className="border-r border-white/5 bg-[#232523]/80 p-3 text-[11px] text-muted">
          <div className="mb-5 flex gap-1.5 px-1 pt-1">
            <span className="size-3 rounded-full bg-[#ff5f57]" />
            <span className="size-3 rounded-full bg-[#febc2e]" />
            <span className="size-3 rounded-full bg-[#28c840]" />
          </div>
          <p className="px-2 pb-1 font-medium text-faint">Device</p>
          <div className="mb-3 rounded-lg bg-[#2d6cdf] px-2 py-1.5 text-white">
            <p className="font-medium">iPhone</p>
            <p className="text-[10px] text-white/75">Ready for agents</p>
          </div>
          <p className="px-2 pb-1 font-medium text-faint">Agents</p>
          <p className="px-2 py-1 text-paper/80">Connect</p>
          <p className="flex justify-between px-2 py-1 text-paper/80">
            Activity <span className="text-faint">12</span>
          </p>
          <p className="px-2 pb-1 pt-3 font-medium text-faint">Cloud</p>
          <p className="flex justify-between px-2 py-1 text-paper/80">
            Remote Access <span className="text-faint">On</span>
          </p>
        </div>

        {/* Stage */}
        <div className="relative flex flex-col items-center bg-gradient-to-b from-[#3a2f45] via-[#26242d] to-[#1b1d1b] px-6 pb-6 pt-12">
          <div className="absolute left-5 top-4 text-left">
            <p className="text-[12px] font-semibold">iPhone</p>
            <p className="text-[10px] text-muted">Ready for agents</p>
          </div>
          <div className="relative w-[170px] rounded-[34px] bg-black p-[7px] shadow-2xl ring-1 ring-white/25 sm:w-[190px]">
            <div className="relative aspect-[9/19.5] overflow-hidden rounded-[28px] bg-gradient-to-br from-[#6d4bd1] via-[#c2537b] to-[#f2a65a]">
              <div className="flex justify-between px-4 pt-2.5 text-[8px] font-semibold text-white">
                <span>9:41</span>
                <span>●●●</span>
              </div>
              <div className="grid grid-cols-4 gap-x-2.5 gap-y-3 px-3 pt-4">
                {icons.map((gradient, index) => (
                  <div key={gradient} className="relative">
                    <div className={`aspect-square rounded-[9px] bg-gradient-to-br ${gradient} shadow-sm`} />
                    {index === 7 && (
                      <span className="absolute inset-0 -m-1 animate-ping rounded-full bg-white/60 motion-reduce:hidden" />
                    )}
                  </div>
                ))}
              </div>
              <div className="absolute inset-x-2 bottom-2 grid grid-cols-4 gap-2.5 rounded-[18px] bg-white/25 p-2 backdrop-blur">
                {icons.slice(0, 4).map((gradient) => (
                  <div key={gradient} className={`aspect-square rounded-[9px] bg-gradient-to-br ${gradient}`} />
                ))}
              </div>
            </div>
          </div>
          <div className="mt-5 flex items-center gap-2.5">
            <span className="glass size-8 rounded-full" />
            <span className="glass flex h-8 w-40 items-center rounded-full px-3 text-[10px] text-muted">Type on iPhone</span>
            <span className="glass size-8 rounded-full" />
          </div>
        </div>

        {/* Inspector */}
        <div className="hidden border-l border-white/5 bg-[#202220]/80 p-4 text-[11px] md:block">
          <p className="pb-2 font-medium text-faint">Activity</p>
          {[
            ["open_app", "Opened Settings"],
            ["tap_text", "Tapped “Wi-Fi”"],
            ["read_screen", "21 lines of text"],
            ["swipe", "Scrolled the list"],
            ["type_text", "Typed 14 characters"],
          ].map(([tool, summary]) => (
            <div key={tool} className="mb-1.5 rounded-lg bg-white/[0.04] px-2.5 py-2">
              <p className="flex items-center gap-1.5 font-medium text-paper/90">
                <span className="size-1.5 rounded-full bg-lime" />
                {tool}
              </p>
              <p className="pl-3 text-muted">{summary}</p>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
