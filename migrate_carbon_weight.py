#!/usr/bin/env python3
"""Convert Carbon Diet Coach weight export to Fuel-compatible import file."""

import sys
import pandas as pd
import openpyxl

CUTOFF = "2021-05-01"
KG_TO_LB = 2.20462
INPUT_DEFAULT = "Carbon_Export_20260607.xlsx"
OUTPUT = "carbon_weight_import.xlsx"


def main():
    input_path = sys.argv[1] if len(sys.argv) > 1 else INPUT_DEFAULT

    df = pd.read_excel(input_path, sheet_name="Weights")

    # Drop deleted entries and rows missing weight
    df = df[df["deleted_at"].isna()]
    df = df[df["bodyWeight (kg)"].notna() & (df["bodyWeight (kg)"] != 0)]

    # Apply date cutoff
    df = df[df["date"] >= CUTOFF]

    # Convert and round
    df = df[["date", "bodyWeight (kg)"]].copy()
    df["lb"] = (df["bodyWeight (kg)"] * KG_TO_LB).round(1)
    df = df[["date", "lb"]].sort_values("date").reset_index(drop=True)

    # Write output
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Weight Log"
    ws.append(["date", "lb"])
    for _, row in df.iterrows():
        ws.append([str(row["date"]), row["lb"]])
    wb.save(OUTPUT)

    n = len(df)
    date_range = f"{df['date'].iloc[0]} → {df['date'].iloc[-1]}" if n else "—"
    print(f"Converted {n} entries  |  {date_range}  →  {OUTPUT}")


if __name__ == "__main__":
    main()
