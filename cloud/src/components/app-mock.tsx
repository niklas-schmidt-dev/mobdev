const icons = [
  "from-sky-400 to-blue-600",
  "from-amber-300 to-orange-500",
  "from-emerald-300 to-green-600",
  "from-zinc-100 to-zinc-300",
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

const activity = [
  ["open_app", "Opened Settings"],
  ["tap_text", "Tapped “Wi-Fi”"],
  ["read_screen", "21 lines of text"],
  ["swipe", "Scrolled the list"],
  ["type_text", "Typed 14 characters"],
];

/**
 * A drawing of the Mobdev window in light appearance, so the page never shows anyone's real phone.
 * Phones get only the stage with the iPhone; the sidebar joins from `sm` and the activity column from `md`.
 */
export function AppMock() {
  return (
    <div
      aria-hidden="true"
      className="relative mx-auto w-full max-w-4xl overflow-hidden rounded-[18px] bg-white text-left shadow-[0_30px_80px_-20px_rgba(0,0,0,0.28),0_0_0_1px_rgba(0,0,0,0.06)]"
    >
      <div className="grid grid-cols-1 sm:grid-cols-[150px_minmax(0,1fr)] md:grid-cols-[180px_minmax(0,1fr)_210px]">
        {/* Sidebar */}
        <div className="hidden bg-[#f3f3f5] p-3 text-[11px] text-muted sm:block">
          <div className="mb-5 flex gap-1.5 px-1 pt-1">
            <span className="size-3 rounded-full bg-[#ff5f57]" />
            <span className="size-3 rounded-full bg-[#febc2e]" />
            <span className="size-3 rounded-full bg-[#28c840]" />
          </div>
          <p className="px-2 pb-1 font-semibold text-faint">Device</p>
          <div className="mb-3 rounded-md bg-[#0a82ff] px-2 py-1.5 text-white">
            <p className="font-medium">iPhone</p>
            <p className="text-[10px] text-white/80">Ready for agents</p>
          </div>
          <p className="px-2 pb-1 font-semibold text-faint">Agents</p>
          <p className="px-2 py-1 text-ink">Connect</p>
          <p className="flex justify-between px-2 py-1 text-ink">
            Activity <span className="text-faint">12</span>
          </p>
          <p className="px-2 pb-1 pt-3 font-semibold text-faint">Cloud</p>
          <p className="flex justify-between px-2 py-1 text-ink">
            Remote Access <span className="text-faint">On</span>
          </p>
        </div>

        {/* Stage */}
        <div className="relative flex flex-col items-center bg-gradient-to-b from-[#efe9f7] via-[#f7f3f6] to-white px-6 pb-7 pt-12">
          <div className="absolute left-5 top-4">
            <p className="text-[12px] font-semibold text-ink">iPhone</p>
            <p className="text-[10px] text-muted">Ready for agents</p>
          </div>
          <div className="relative w-[160px] rounded-[32px] bg-[#1d1d1f] p-[6px] shadow-[0_20px_40px_-12px_rgba(0,0,0,0.35)] sm:w-[180px]">
            <div className="relative aspect-[9/19.5] overflow-hidden rounded-[26px] bg-gradient-to-br from-[#7b61ff] via-[#e2638f] to-[#ffb36b]">
              <div className="flex justify-between px-4 pt-2.5 text-[8px] font-semibold text-white">
                <span>9:41</span>
                <span>●●●</span>
              </div>
              <div className="grid grid-cols-4 gap-x-2.5 gap-y-3 px-3 pt-4">
                {icons.map((gradient, index) => (
                  <div key={gradient} className="relative">
                    <div className={`aspect-square rounded-[9px] bg-gradient-to-br ${gradient} shadow-sm`} />
                    {index === 7 && (
                      <span className="absolute inset-0 -m-1 animate-ping rounded-full bg-white/70 motion-reduce:hidden" />
                    )}
                  </div>
                ))}
              </div>
              <div className="absolute inset-x-2 bottom-2 grid grid-cols-4 gap-2.5 rounded-[18px] bg-white/30 p-2 backdrop-blur">
                {icons.slice(0, 4).map((gradient) => (
                  <div key={gradient} className={`aspect-square rounded-[9px] bg-gradient-to-br ${gradient}`} />
                ))}
              </div>
            </div>
          </div>
          <div className="mt-5 flex items-center gap-2">
            <span className="size-8 rounded-full bg-white/70 shadow-sm ring-1 ring-black/5 backdrop-blur" />
            <span className="flex h-8 w-36 items-center rounded-full bg-white/70 px-3 text-[10px] text-faint shadow-sm ring-1 ring-black/5 backdrop-blur">
              Type on iPhone
            </span>
            <span className="size-8 rounded-full bg-white/70 shadow-sm ring-1 ring-black/5 backdrop-blur" />
          </div>
        </div>

        {/* Activity */}
        <div className="hidden bg-[#fafafa] p-4 text-[11px] md:block">
          <p className="pb-2 font-semibold text-faint">Activity</p>
          {activity.map(([tool, summary]) => (
            <div key={tool} className="mb-1.5 rounded-lg bg-white px-2.5 py-2 ring-1 ring-black/[0.04]">
              <p className="flex items-center gap-1.5 font-medium text-ink">
                <span className="size-1.5 rounded-full bg-[#34c759]" />
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
