There are 3 json files
1. Config.json has some of the configs, logged in User value is the user 3/4 shown on the Toolbar. This normally comes from OneSign EXO which is being used for Followme Button Manager. For testing purposes create the file with 3/4
2. Masterfile.json is the Master file with all the buttons. Similar to Vergence's CredApplication, there is ISXRunAs.exe whih I am using in some of the congigs.
3. FMBM.json is the user selected button file.

There are 2 executables
1. Toolbar.exe is the one that starts the Toolbar and populates it with Buttons
2. Reserve-Top.exe helps reserve the top space for Toolbar. All applications except those defined as App Exclusions in Config.json are pushed down
3. Also, Top Space for Toolbar as defined in Config.json is the space used by Toolbar
4. Once user exits Toolbar. Reserve-Top readjusts the apps to their original size and then exits.

There is an Icon folder where all the icons used in the application are stored
All logs are stored in a ToolbarApp\logs folder.