#!/usr/bin/env python3


import pandas as pd
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--files', '-f', help='TSV files to collate', required=True, nargs='+')
parser.add_argument('--output', '-o', help='Name of output file', default='all_species_ids.tsv')
args = parser.parse_args()

df = pd.concat([pd.read_csv(f, sep='\t') for f in args.files])
df.sort_values(by='taxonomy', inplace=True)
df.to_csv(args.output, sep='\t', index=False)