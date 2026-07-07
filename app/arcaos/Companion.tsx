"use client";

// Parametric ARCA companion renderer.
// Draws a CompanionLook (from lib/companion/generate) in the brand grammar of
// public/brand/arca-companion.svg — rounded head, two oversized glowing eyes,
// antenna — with generated variation: ears, gem, mouth, cheeks, industry emblem.
// Moods mirror the desktop companion vocabulary.

import { useEffect, useId, useState } from "react";
import type { CompanionLook } from "@/lib/companion/generate";

export type CompanionMood =
  | "idle"
  | "listening"
  | "thinking"
  | "happy"
  | "guarding"
  | "reporting";

function useBlink(active: boolean) {
  const [blink, setBlink] = useState(false);
  useEffect(() => {
    if (!active) {
      setBlink(false);
      return;
    }
    let outer: ReturnType<typeof setTimeout>;
    let inner: ReturnType<typeof setTimeout>;
    function cycle() {
      outer = setTimeout(() => {
        setBlink(true);
        inner = setTimeout(() => {
          setBlink(false);
          cycle();
        }, 130);
      }, 2400 + Math.random() * 2600);
    }
    cycle();
    return () => {
      clearTimeout(outer);
      clearTimeout(inner);
    };
  }, [active]);
  return blink;
}

function Emblem({ kind, accent, x, y }: { kind: CompanionLook["antenna"]; accent: string; x: number; y: number }) {
  switch (kind) {
    case "leaf":
      return (
        <path
          d={`M${x} ${y + 7} C ${x - 9} ${y - 2} ${x - 5} ${y - 11} ${x} ${y - 9} C ${x + 5} ${y - 11} ${x + 9} ${y - 2} ${x} ${y + 7} Z`}
          fill={accent}
        />
      );
    case "star":
      return (
        <path
          d={`M${x} ${y - 9} L${x + 2.6} ${y - 2.6} L${x + 9} ${y} L${x + 2.6} ${y + 2.6} L${x} ${y + 9} L${x - 2.6} ${y + 2.6} L${x - 9} ${y} L${x - 2.6} ${y - 2.6} Z`}
          fill={accent}
        />
      );
    case "spark":
      return (
        <path
          d={`M${x + 4} ${y - 9} L${x - 4} ${y + 1} L${x + 1} ${y + 1} L${x - 3} ${y + 9} L${x + 5} ${y - 1} L${x} ${y - 1} Z`}
          fill={accent}
        />
      );
    case "coin":
      return (
        <g>
          <circle cx={x} cy={y} r={7.5} fill={accent} />
          <circle cx={x} cy={y} r={4} fill="none" stroke="rgba(0,0,0,0.35)" strokeWidth={1.6} />
        </g>
      );
    case "shield":
      return (
        <path
          d={`M${x} ${y - 8} L${x + 7} ${y - 5} C ${x + 7} ${y + 2} ${x + 4} ${y + 6} ${x} ${y + 9} C ${x - 4} ${y + 6} ${x - 7} ${y + 2} ${x - 7} ${y - 5} Z`}
          fill={accent}
        />
      );
    case "flag":
      return (
        <g>
          <line x1={x - 1} y1={y - 9} x2={x - 1} y2={y + 8} stroke={accent} strokeWidth={2.4} strokeLinecap="round" />
          <path d={`M${x + 1} ${y - 8} L${x + 10} ${y - 5} L${x + 1} ${y - 2} Z`} fill={accent} />
        </g>
      );
    default:
      return <circle cx={x} cy={y} r={6.5} fill={accent} className="cmp-antenna-dot" />;
  }
}

function Gem({ shape, accent, x, y }: { shape: CompanionLook["gem"]; accent: string; x: number; y: number }) {
  switch (shape) {
    case "round":
      return <circle cx={x} cy={y} r={5.5} fill={accent} opacity={0.9} />;
    case "leaf":
      return (
        <path
          d={`M${x} ${y + 5} C ${x - 6} ${y - 1} ${x - 3} ${y - 7} ${x} ${y - 6} C ${x + 3} ${y - 7} ${x + 6} ${y - 1} ${x} ${y + 5} Z`}
          fill={accent}
          opacity={0.9}
        />
      );
    case "star":
      return (
        <path
          d={`M${x} ${y - 6} L${x + 1.8} ${y - 1.8} L${x + 6} ${y} L${x + 1.8} ${y + 1.8} L${x} ${y + 6} L${x - 1.8} ${y + 1.8} L${x - 6} ${y} L${x - 1.8} ${y - 1.8} Z`}
          fill={accent}
          opacity={0.9}
        />
      );
    case "square":
      return <rect x={x - 4.5} y={y - 4.5} width={9} height={9} rx={2} fill={accent} opacity={0.9} transform={`rotate(45 ${x} ${y})`} />;
    default:
      return <rect x={x - 5} y={y - 5} width={10} height={10} rx={1.5} fill={accent} opacity={0.9} transform={`rotate(45 ${x} ${y})`} />;
  }
}

export function GeneratedCompanion({
  look,
  mood = "idle",
  size = 200,
}: {
  look: CompanionLook;
  mood?: CompanionMood;
  size?: number;
}) {
  const uid = useId().replace(/[^a-zA-Z0-9]/g, "");
  const blinkable = mood === "idle" || mood === "listening" || mood === "reporting";
  const blink = useBlink(blinkable);

  const headX = 110 - look.headW / 2;
  const headY = 200 - look.headH;
  const eyeCy = headY + look.headH * 0.52;
  const eyeDx = look.headW * 0.17;
  const leftEyeCx = 110 - eyeDx;
  const rightEyeCx = 110 + eyeDx;

  const eyeBase =
    look.eye === "tall" ? { rx: 12, ry: 23 } : look.eye === "round" ? { rx: 15, ry: 17 } : { rx: 17, ry: 13.5 };

  let eyeRx = eyeBase.rx;
  let eyeRy = eyeBase.ry;
  let eyeShiftY = 0;
  if (mood === "listening") eyeRy = eyeBase.ry * 1.15;
  if (mood === "thinking") {
    eyeRx = eyeBase.rx * 0.45;
    eyeRy = eyeBase.ry * 0.4;
    eyeShiftY = -6;
  }
  if (mood === "guarding") eyeRy = eyeBase.ry * 0.48;
  if (blink) eyeRy = 2.2;

  const mouthY = eyeCy + look.headH * 0.24;
  const antennaTopY = headY - 20;

  return (
    <svg
      className={`cmp cmp--${mood}`}
      viewBox="0 0 220 236"
      width={size}
      height={Math.round((size / 220) * 236)}
      role="img"
      aria-label="ARCA companion"
    >
      <defs>
        <linearGradient id={`body${uid}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={look.bodyTop} />
          <stop offset="1" stopColor={look.bodyBottom} />
        </linearGradient>
        <radialGradient id={`eye${uid}`} cx="0.5" cy="0.38" r="0.78">
          <stop offset="0" stopColor={look.eyeTop} />
          <stop offset="0.5" stopColor={look.eyeMid} />
          <stop offset="1" stopColor={look.eyeGlow} />
        </radialGradient>
        <radialGradient id={`halo${uid}`} cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor={look.eyeGlow} stopOpacity={mood === "reporting" ? 0.55 : 0.4} />
          <stop offset="1" stopColor={look.eyeGlow} stopOpacity="0" />
        </radialGradient>
      </defs>

      {/* ambient glow */}
      <ellipse className="cmp-halo" cx="110" cy="132" rx="104" ry="92" fill={`url(#halo${uid})`} />

      {/* guard ring */}
      {mood === "guarding" && (
        <circle
          className="cmp-ring"
          cx="110"
          cy="132"
          r="98"
          fill="none"
          stroke={look.accent}
          strokeWidth="2"
          strokeDasharray="10 14"
          strokeLinecap="round"
          opacity="0.7"
        />
      )}

      {/* listening pulse */}
      {mood === "listening" && (
        <>
          <circle className="cmp-pulse cmp-pulse--1" cx="110" cy="132" r="86" fill="none" stroke={look.eyeGlow} strokeWidth="1.5" />
          <circle className="cmp-pulse cmp-pulse--2" cx="110" cy="132" r="86" fill="none" stroke={look.eyeGlow} strokeWidth="1.5" />
        </>
      )}

      <g className="cmp-body">
        {/* ears */}
        {look.ear === "nub" && (
          <>
            <circle cx={headX + 18} cy={headY + 6} r="15" fill={`url(#body${uid})`} stroke={look.strokeCol} strokeWidth="2.5" />
            <circle cx={headX + look.headW - 18} cy={headY + 6} r="15" fill={`url(#body${uid})`} stroke={look.strokeCol} strokeWidth="2.5" />
          </>
        )}
        {look.ear === "point" && (
          <>
            <path
              d={`M${headX + 10} ${headY + 22} L${headX + 20} ${headY - 16} L${headX + 44} ${headY + 8} Z`}
              fill={`url(#body${uid})`}
              stroke={look.strokeCol}
              strokeWidth="2.5"
              strokeLinejoin="round"
            />
            <path
              d={`M${headX + look.headW - 10} ${headY + 22} L${headX + look.headW - 20} ${headY - 16} L${headX + look.headW - 44} ${headY + 8} Z`}
              fill={`url(#body${uid})`}
              stroke={look.strokeCol}
              strokeWidth="2.5"
              strokeLinejoin="round"
            />
          </>
        )}

        {/* antenna + industry emblem */}
        <line x1="110" y1={headY + 4} x2="110" y2={antennaTopY} stroke={look.accent} strokeWidth="4" strokeLinecap="round" />
        <g className="cmp-emblem">
          <Emblem kind={look.antenna} accent={look.accent} x={110} y={antennaTopY - 8} />
        </g>

        {/* head */}
        <rect
          x={headX}
          y={headY}
          width={look.headW}
          height={look.headH}
          rx={look.headRx}
          fill={`url(#body${uid})`}
          stroke={look.strokeCol}
          strokeWidth="2.5"
        />

        {/* forehead gem */}
        <Gem shape={look.gem} accent={look.accent} x={110} y={headY + 26} />

        {/* eyes */}
        <g className="cmp-eyes">
          {mood === "happy" ? (
            <>
              <path
                d={`M${leftEyeCx - eyeBase.rx} ${eyeCy + 4} Q ${leftEyeCx} ${eyeCy - eyeBase.ry} ${leftEyeCx + eyeBase.rx} ${eyeCy + 4}`}
                fill="none"
                stroke={`url(#eye${uid})`}
                strokeWidth="7"
                strokeLinecap="round"
              />
              <path
                d={`M${rightEyeCx - eyeBase.rx} ${eyeCy + 4} Q ${rightEyeCx} ${eyeCy - eyeBase.ry} ${rightEyeCx + eyeBase.rx} ${eyeCy + 4}`}
                fill="none"
                stroke={`url(#eye${uid})`}
                strokeWidth="7"
                strokeLinecap="round"
              />
            </>
          ) : (
            <>
              <ellipse cx={leftEyeCx} cy={eyeCy + eyeShiftY} rx={eyeRx} ry={eyeRy} fill={`url(#eye${uid})`} />
              <ellipse cx={rightEyeCx} cy={eyeCy + eyeShiftY} rx={eyeRx} ry={eyeRy} fill={`url(#eye${uid})`} />
              {!blink && mood !== "thinking" && (
                <>
                  <circle cx={leftEyeCx - 4} cy={eyeCy + eyeShiftY - eyeRy * 0.42} r="3.2" fill="#fff" opacity="0.85" />
                  <circle cx={rightEyeCx - 4} cy={eyeCy + eyeShiftY - eyeRy * 0.42} r="3.2" fill="#fff" opacity="0.85" />
                </>
              )}
            </>
          )}
        </g>

        {/* thinking orbit */}
        {mood === "thinking" && (
          <g className="cmp-orbit" style={{ transformOrigin: "110px 132px" }}>
            <circle cx="110" cy="34" r="4" fill={look.accent} />
          </g>
        )}

        {/* mouth */}
        {(look.mouth === "smile" || mood === "happy") && (
          <path
            d={`M${110 - 16} ${mouthY} Q 110 ${mouthY + 12} ${110 + 16} ${mouthY}`}
            fill="none"
            stroke={look.strokeCol}
            strokeWidth="3"
            strokeLinecap="round"
          />
        )}
        {look.mouth === "cat" && mood !== "happy" && (
          <path
            d={`M${110 - 14} ${mouthY} Q ${110 - 7} ${mouthY + 7} 110 ${mouthY} Q ${110 + 7} ${mouthY + 7} ${110 + 14} ${mouthY}`}
            fill="none"
            stroke={look.strokeCol}
            strokeWidth="2.6"
            strokeLinecap="round"
          />
        )}
        {look.mouth === "line" && mood !== "happy" && (
          <line x1={110 - 10} y1={mouthY + 2} x2={110 + 10} y2={mouthY + 2} stroke={look.strokeCol} strokeWidth="2.6" strokeLinecap="round" />
        )}

        {/* cheeks */}
        {look.cheeks && (
          <>
            <ellipse cx={leftEyeCx - eyeBase.rx - 8} cy={eyeCy + eyeBase.ry * 0.6} rx="8" ry="5" fill={look.accent} opacity="0.22" />
            <ellipse cx={rightEyeCx + eyeBase.rx + 8} cy={eyeCy + eyeBase.ry * 0.6} rx="8" ry="5" fill={look.accent} opacity="0.22" />
          </>
        )}

        {/* freckles */}
        {Array.from({ length: look.freckles }).map((_, i) => (
          <circle
            key={i}
            cx={110 + (i - 1) * 9}
            cy={mouthY + 14}
            r="1.6"
            fill={look.strokeCol}
            opacity="0.55"
          />
        ))}
      </g>

      {/* reporting sparkles */}
      {mood === "reporting" && (
        <g className="cmp-sparkles" fill={look.accent}>
          <path d="M36 70 l3 7 7 3 -7 3 -3 7 -3 -7 -7 -3 7 -3 Z" opacity="0.8" />
          <path d="M186 96 l2.4 5.6 5.6 2.4 -5.6 2.4 -2.4 5.6 -2.4 -5.6 -5.6 -2.4 5.6 -2.4 Z" opacity="0.6" />
        </g>
      )}
    </svg>
  );
}

/* Pre-hatch core: what asks the onboarding questions before it has a face. */
export function CoreEgg({ size = 160, cracking = false }: { size?: number; cracking?: boolean }) {
  const uid = useId().replace(/[^a-zA-Z0-9]/g, "");
  return (
    <svg
      className={`egg ${cracking ? "egg--cracking" : ""}`}
      viewBox="0 0 160 180"
      width={size}
      height={Math.round((size / 160) * 180)}
      role="img"
      aria-label="ARCA core"
    >
      <defs>
        <linearGradient id={`eggBody${uid}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#2a1812" />
          <stop offset="1" stopColor="#150c07" />
        </linearGradient>
        <radialGradient id={`eggGlow${uid}`} cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor="#ff7a1a" stopOpacity="0.45" />
          <stop offset="1" stopColor="#ff7a1a" stopOpacity="0" />
        </radialGradient>
      </defs>
      <ellipse cx="80" cy="96" rx="76" ry="80" fill={`url(#eggGlow${uid})`} />
      <path
        d="M80 16 C 122 16 142 62 142 104 C 142 142 114 164 80 164 C 46 164 18 142 18 104 C 18 62 38 16 80 16 Z"
        fill={`url(#eggBody${uid})`}
        stroke="#7a4a2a"
        strokeWidth="2.5"
      />
      <circle className="egg-light" cx="80" cy="92" r="10" fill="#ff7a1a" />
      {cracking && (
        <g stroke="#ff9a3c" strokeWidth="2.4" strokeLinecap="round" fill="none" className="egg-cracks">
          <path d="M62 58 L74 74 L64 90" />
          <path d="M100 52 L92 70 L104 84 L96 100" />
          <path d="M78 116 L88 130" />
        </g>
      )}
    </svg>
  );
}
