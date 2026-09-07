/* Shared presentational primitives. */
const { useState, useEffect, useRef } = React;

const Switch = ({ on, onChange }) => (
  <button
    className={"switch" + (on ? " on" : "")}
    role="switch"
    aria-checked={on}
    onClick={(e) => { e.stopPropagation(); onChange && onChange(!on); }}
  />
);

const Seg = ({ value, options, onChange }) => (
  <div className="seg" role="tablist">
    {options.map((o) => (
      <button
        key={o.value}
        role="tab"
        aria-selected={value === o.value}
        className={value === o.value ? "on" : ""}
        onClick={() => onChange(o.value)}
      >
        {o.label}
        {o.count != null && <span style={{ opacity: 0.55, marginLeft: 5 }}>{o.count}</span>}
      </button>
    ))}
  </div>
);

const IconBtn = ({ icon: Icon, on, title, onClick, size = 17 }) => (
  <button className={"icon-btn" + (on ? " on" : "")} title={title} aria-label={title} onClick={onClick}>
    <Icon size={size} />
  </button>
);

const FieldRow = ({ title, desc, children }) => (
  <div className="field-row">
    <div className="fl">
      <div className="t">{title}</div>
      {desc && <div className="d cjk">{desc}</div>}
    </div>
    {children}
  </div>
);

Object.assign(window, { Switch, Seg, IconBtn, FieldRow });
