import type { ReactNode } from "react";

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
];

/** Newest last, as an agent works through the dev loop on the simulator and then checks Android. */
const activity = [
  ["install_app", "Installed Notes.app"],
  ["launch_app", "com.example.notes is running"],
  ["tap_text", "Tapped “New Note”"],
  ["type_text", "Typed 9 characters"],
  ["logs", "12 lines, no errors"],
  ["open_app", "Opened Settings on Pixel 9"],
];

const sidebarRow = "flex items-center justify-between px-2 py-1 text-ink";

/**
 * A drawing of the Mobdev window on All Devices, in the visitor's appearance, so the page never shows
 * anyone's real phone: an iPhone on the desk, a simulator running the app being built and an Android
 * emulator. Phones get only the stage; the sidebar joins from `sm` and the activity column from `md`.
 */
export function AppMock() {
  return (
    <div
      aria-hidden="true"
      className="relative mx-auto w-full max-w-4xl overflow-hidden rounded-[18px] bg-white text-left shadow-[0_30px_80px_-20px_rgba(0,0,0,0.28),0_0_0_1px_rgba(0,0,0,0.06)] dark:bg-[#1e1e1e] dark:shadow-none dark:ring-1 dark:ring-white/15"
    >
      <div className="grid grid-cols-1 sm:grid-cols-[150px_minmax(0,1fr)] md:grid-cols-[170px_minmax(0,1fr)_200px]">
        {/* Sidebar, as in MainView.swift */}
        <div className="hidden bg-[#f3f3f5] p-3 text-[11px] text-muted sm:block dark:bg-[#29292b]">
          <div className="mb-5 flex gap-1.5 px-1 pt-1">
            <span className="size-3 rounded-full bg-[#ff5f57]" />
            <span className="size-3 rounded-full bg-[#febc2e]" />
            <span className="size-3 rounded-full bg-[#28c840]" />
          </div>
          <p className="mb-3 flex justify-between rounded-md bg-[#0a82ff] px-2 py-1.5 font-medium text-white">
            All Devices <span className="text-white/80">3</span>
          </p>
          <p className="px-2 pb-1 font-semibold text-faint">This Mac</p>
          <SidebarDevice name="iPhone" />
          <p className="px-2 pb-1 pt-2 font-semibold text-faint">Simulators and Android</p>
          <SidebarDevice name="iPhone 17 Pro" />
          <SidebarDevice name="Pixel 9" />
          <p className="px-2 pb-1 pt-2 font-semibold text-faint">Agents</p>
          <p className={sidebarRow}>Connect</p>
          <p className={sidebarRow}>
            Activity <span className="text-faint">12</span>
          </p>
          <p className="px-2 pb-1 pt-2 font-semibold text-faint">Cloud</p>
          <p className={sidebarRow}>
            Remote Access <span className="text-faint">On</span>
          </p>
        </div>

        {/* Stage: All Devices */}
        <div className="relative bg-gradient-to-b from-[#efe9f7] via-[#f7f3f6] to-white px-3 pb-6 pt-4 sm:px-5 dark:from-[#2a2433] dark:via-[#221f25] dark:to-[#1e1e1e]">
          <p className="text-[12px] font-semibold text-ink">All Devices</p>
          <p className="text-[10px] text-muted">3 ready, 3 connected</p>
          <p className="mt-4 text-[11px] font-semibold text-ink">This Mac</p>
          <div className="mt-2 grid grid-cols-3 gap-2 sm:gap-3">
            <DeviceCard name="iPhone" detail="iPhone 16 · iOS 27">
              <IPhone bezel="bg-[#1d1d1f]">
                <HomeScreen />
              </IPhone>
            </DeviceCard>
            <DeviceCard name="iPhone 17 Pro" detail="Simulator · iOS 27">
              <IPhone bezel="bg-[#9a9a9f] dark:bg-[#6e6e73]">
                <NotesScreen />
              </IPhone>
            </DeviceCard>
            <DeviceCard name="Pixel 9" detail="Android 16">
              <Android />
            </DeviceCard>
          </div>
        </div>

        {/* Activity */}
        <div className="hidden bg-[#fafafa] p-4 text-[11px] md:block dark:bg-[#232325]">
          <p className="pb-2 font-semibold text-faint">Activity</p>
          {activity.map(([tool, summary]) => (
            <div
              key={tool}
              className="mb-1.5 rounded-lg bg-white px-2.5 py-2 ring-1 ring-black/[0.04] dark:bg-white/[0.06] dark:ring-white/[0.06]"
            >
              <p className="flex items-center gap-1.5 font-medium text-ink">
                <span className="size-1.5 rounded-full bg-[#34c759]" />
                {tool}
              </p>
              <p className="truncate pl-3 text-muted">{summary}</p>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function SidebarDevice({ name }: { name: string }) {
  return (
    <div className="px-2 py-1">
      <p className="text-ink">{name}</p>
      <p className="text-[10px] text-faint">Ready for agents</p>
    </div>
  );
}

function DeviceCard({ name, detail, children }: { name: string; detail: string; children: ReactNode }) {
  return (
    <div className="flex min-w-0 flex-col items-center rounded-2xl bg-white/60 px-2 pb-3 pt-4 ring-1 ring-black/5 backdrop-blur dark:bg-white/[0.06] dark:ring-white/10">
      <div className="w-full max-w-[104px]">{children}</div>
      <p className="mt-3 w-full truncate text-center text-[11px] font-semibold text-ink">{name}</p>
      <p className="w-full truncate text-center text-[9px] text-muted sm:text-[10px]">{detail}</p>
      <span className="mt-1.5 inline-flex items-center gap-1 rounded-full bg-black/5 px-2 py-0.5 text-[9px] font-medium text-muted dark:bg-white/10">
        <span className="size-1.5 rounded-full bg-[#34c759]" />
        Ready
      </span>
    </div>
  );
}

function IPhone({ bezel, children }: { bezel: string; children: ReactNode }) {
  return (
    <div className={`rounded-[18px] p-[3px] shadow-[0_12px_24px_-10px_rgba(0,0,0,0.35)] dark:shadow-none ${bezel}`}>
      <div className="relative aspect-[9/19.5] overflow-hidden rounded-[15px]">
        {children}
        <span className="absolute left-1/2 top-[5px] h-[5px] w-[22px] -translate-x-1/2 rounded-full bg-black" />
      </div>
    </div>
  );
}

function HomeScreen() {
  return (
    <div className="h-full bg-gradient-to-br from-[#7b61ff] via-[#e2638f] to-[#ffb36b]">
      <div className="grid grid-cols-4 gap-x-1.5 gap-y-2 px-2 pt-6">
        {icons.map((gradient) => (
          <div key={gradient} className={`aspect-square rounded-[5px] bg-gradient-to-br ${gradient}`} />
        ))}
      </div>
      <div className="absolute inset-x-1.5 bottom-1.5 grid grid-cols-4 gap-1.5 rounded-[10px] bg-white/30 p-1.5 backdrop-blur">
        {icons.slice(0, 4).map((gradient) => (
          <div key={gradient} className={`aspect-square rounded-[5px] bg-gradient-to-br ${gradient}`} />
        ))}
      </div>
    </div>
  );
}

/** The app being built, where the agent just tapped "New Note". */
function NotesScreen() {
  return (
    <div className="h-full bg-[#f2f2f7] px-2 pt-6 dark:bg-black">
      <p className="text-[10px] font-bold text-ink">Notes</p>
      <div className="mt-1.5 space-y-px overflow-hidden rounded-[6px] bg-white dark:bg-[#1c1c1e]">
        {[70, 52, 84, 60, 44].map((width) => (
          <div key={width} className="px-1.5 py-1.5">
            <div className="h-[3px] rounded-full bg-ink/70" style={{ width: `${width}%` }} />
            <div className="mt-1 h-[3px] w-4/5 rounded-full bg-ink/15" />
          </div>
        ))}
      </div>
      <div className="absolute bottom-3 right-2.5">
        <span className="relative block size-[18px] rounded-full bg-[#ffcc00]">
          <span className="absolute inset-0 -m-1 animate-ping rounded-full bg-[#ffcc00]/60 motion-reduce:hidden" />
        </span>
      </div>
    </div>
  );
}

function Android() {
  return (
    <div className="rounded-[13px] bg-[#202124] p-[3px] shadow-[0_12px_24px_-10px_rgba(0,0,0,0.35)] dark:shadow-none dark:ring-1 dark:ring-white/15">
      <div className="relative aspect-[9/19.5] overflow-hidden rounded-[10px] bg-gradient-to-b from-[#134e4a] via-[#0f766e] to-[#99f6e4]">
        <span className="absolute left-1/2 top-[5px] size-[5px] -translate-x-1/2 rounded-full bg-black" />
        <p className="px-2 pt-6 text-[15px] font-light leading-none text-white">9:41</p>
        <p className="px-2 pt-1 text-[7px] text-white/80">Wed, Sep 30</p>
        <div className="absolute inset-x-2 bottom-7 grid grid-cols-4 gap-1.5">
          {icons.slice(4, 8).map((gradient) => (
            <div key={gradient} className={`aspect-square rounded-full bg-gradient-to-br ${gradient}`} />
          ))}
        </div>
        <div className="absolute inset-x-2 bottom-2 h-[12px] rounded-full bg-white/85" />
      </div>
    </div>
  );
}
