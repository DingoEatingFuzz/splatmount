# Splatmount

A utility for mounting every subdirectory of a directory in a target directory.

```
splatmount [source] [target] [fstype]
```

```
# Before           #After
original           original     
├── sub1           ├── sub1     
├── sub2           ├── sub2     
├── sub3           ├── sub3     
└── .hidden        └── .hidden  
mount              mount        
└── sub1           ├── sub1     
                   ├── sub2     
                   └── sub3     
```

## Details

1. The mounts will always be bind mounts (i.e., `mount -o bind [source] [target]` equivalents).
2. When the target directory does not have a matching subdirectory, it will be made automatically
3. If any mount or mkdir fails, the entire transaction is aborted. No broken states.

## FAQ

**Q: Why would I use this instead of just mounting the parent directory?**
If you can do that, then do that. That sounds way better. Unfortunately, sometimes systems touch in peculiar
ways that require more finessing over the directory structure.

**Q: Why would I mount the directories instead of symlinking them?**
See above answer.
