#!/usr/bin/env python3


import pandas as pd
import argparse
from collections import Counter

parser = argparse.ArgumentParser()
parser.add_argument('-f', '--file', help='sendsketch.sh output', required=True)
parser.add_argument('-o', '--output', help='output file', default='species_id.csv')
parser.add_argument('--id', help='sample ID', required=True)
args = parser.parse_args()

def get_species(sketch_df):
    try:
        tax_list = sketch_df['taxName']
    except KeyError:
        top_genus = 'NA'
        top_tax = 'NA'
        return top_genus, top_tax
    top_tax = tax_list[0]
    genus_list = list(map(lambda hit: hit.split(' ')[0], tax_list))
    genus_occurence = Counter(genus_list)
    top_genus, genus_count = genus_occurence.most_common(1)[0]
    
    return top_genus, top_tax


df = pd.read_csv(args.file, sep='\t', skiprows=2)
genus, tax = get_species(df)
mlst_df = pd.DataFrame({'sample': [args.id],
						 'genus': genus, 
						 'taxonomy': tax})
mlst_df.to_csv(args.output, sep='\t', index=False)

	

