#!/usr/bin/python3
# Convert json on stdin into bash variable settings on stdout.
# Lists made up of dictionaries including a 'name' key have an extra
#   variable defined listing the names.
# If command line parameter given, it will be the prefix on all the
#  variable names, default just an underscore.
#
# This source file is Copyright (c) 2021, FERMI NATIONAL
#   ACCELERATOR LABORATORY.  All rights reserved.

import sys
import json
import re

def collapsestr(item):
    if type(item) is dict and len(item) == 1 and next(iter(item.values())) is None:
        # special case for over-zealous yaml parsing of scope ending in colon
        key = next(iter(item.keys()))
        return(key + ':')
    return str(item)

def checkbashvar(name):
    modname = name.replace('-', '_')
    if not re.match(r'^\w+$', modname):
        print("Unacceptable character in name ", name, file=sys.stderr)
        sys.exit(1)
    return modname

def convertbash(pfx,data):
    if type(data) is dict:
        for key in data:
            convertbash(pfx + '_' + checkbashvar(key), data[key])
    elif type(data) is list:
        if len(data) > 0 and type(data[0]) is dict:
            names = []
            for item in data:
                if 'name' not in item:
                    print("'name' missing in a list under", pfx, file=sys.stderr)
                    sys.exit(1)
                name = item['name']
                names.append(name)
                del item['name']
                convertbash(pfx + '_' + checkbashvar(name), item)
            convertbash(pfx, ' '.join(names))
        else:
            convertbash(pfx, ' '.join([collapsestr(item) for item in data]))
    elif data is not None:
        print(pfx + '="' + str(data) + '"')
    else:
        print(pfx + '=""')


def main():
    combined = json.load(sys.stdin)

    if len(sys.argv) > 1:
        convertbash(sys.argv[1], combined)
    else:
        convertbash("", combined)

if __name__ == '__main__':
    main()
