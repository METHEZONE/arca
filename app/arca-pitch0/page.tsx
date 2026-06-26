"use client";

import "./pitch.css";
import Deck from "./Deck";
import { slides } from "./slides";

export default function PitchPage() {
  return <Deck slides={slides} />;
}
