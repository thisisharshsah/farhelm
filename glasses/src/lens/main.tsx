import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "../ui/tokens.css";
import { App } from "./App.tsx";
import "./lens.css";

const root = document.getElementById("root");
if (!root) throw new Error("glasses.html is missing #root");
createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
