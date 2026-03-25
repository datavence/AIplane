/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import * as React from "react";

import type { ISvgIcons } from "../type";

export function PlaneLogo({ width = "85", height = "52", className, color = "currentColor" }: ISvgIcons) {
  return (
    <svg
      width={width}
      height={height}
      viewBox="2898 7854 6259 5586"
      fill={color}
      xmlns="http://www.w3.org/2000/svg"
      className={className}
    >
      <polygon
        fill={color}
        points="7629.97,8555.19 8264.68,8555.03 8310.82,9119.95 8641.91,8109.41"
      />
      <path 
        fill={color}
        d="M4170.86 9863.82l-1128.62 1128.63 879.17 0.11c113.83,0 167.54,-29.91 223.77,-62.11 256.57,-146.92 660.91,-565.09 872.15,-779.24l692.57 -697.8 1513.39 0 0 1487.75 -2334.9 0.08 -676.42 677.24 -656.72 656.5 1011.96 0c141.53,0.05 221.82,-23.99 337.62,-132.82l462.59 -442.72 2676.68 -4.02 0 -2960.22 -2744.61 0 -1128.63 1128.62zm1333.83 359.12l-353.86 359.1 1713.34 0 0 -718.22 -1005.6 0 -353.88 359.12zm1718.6 2257.25l0 410.4 820.81 0 0 -820.81 -820.81 0 0 410.41z"
      />
    </svg>
  );
}
