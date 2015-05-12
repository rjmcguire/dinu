module dinu.commandBuilder;

import
	std.array,
	std.stdio,
	std.range,
	std.string,
	std.conv,
	std.utf,
	std.uni,
	std.algorithm,
	std.parallelism,
	std.process,
	std.file,
	std.path,
	std.math,
	std.datetime,
	core.thread,
	core.sync.condition,
	draw,
	cli,
	dinu.dinu,
	dinu.util,
	dinu.xclient,
	dinu.content.content,
	dinu.content.output,
	dinu.content.executables,
	dinu.content.files,
	dinu.content.talkProcess,
	dinu.content.bashCompletion,
	dinu.filter,
	dinu.command;


__gshared:


FuzzyFilter!Command choiceFilter;
Command[] output;


void delChar(ref string text, size_t cursor){
	if(cursor < text.length)
		text = text[0..cursor] ~ text[cursor+1..$];
}

void delBackChar(ref string text, ref size_t cursor){
	if(cursor){
		text = text[0..cursor-1] ~ text[cursor..$];
		cursor--;
	}
}

void deleteWordLeft(ref string text, ref size_t cursor){
	if(!text.length)
		return;
	text.delBackChar(cursor);
	bool mode = text[cursor-1].isWhite;
	while(cursor && mode == text[cursor-1].isWhite){
		text = text[0..cursor-1] ~ text[cursor..$];
		cursor--;
	}
}

void deleteWordRight(ref string text, size_t cursor){
	text.delChar(cursor);
	bool mode = text[cursor].isWhite;
	while(cursor && mode == text[cursor-1].isWhite)
		text = text[0..cursor] ~ text[cursor+1..$];
}



class CommandBuilder {

	string[] command;
	size_t editing;
	size_t cursor;

	string filterText;

	Command commandSelected;
	//Picker paramPicker;
	int logIdx=1;
	bool commandHistory;
	string[] scannedDirs;
	Command[] bashCompletions;
	long selected;

	OutputLoader outputLoader;
	ExecutablesLoader execLoader;
	TalkProcessLoader processLoader;
	FilesLoader filesLoader;

	this(){

		choiceFilter = new FuzzyFilter!Command((c){
			if(toString.length && toString[0] == '@' && editing == 0){
				return c.type == Type.processInfo;
			}else if(choiceFilter && commandHistory){
				return c.type == Type.history;
			}else if(!bashCompletions.length && toString.length){
				auto filter = [Type.file, Type.directory];
				if(editing == 0)
					filter ~= [Type.script, Type.desktop, Type.special];
				return filter.canFind(c.type);
			}else if(bashCompletions.length){
				return c.type == Type.bashCompletion;
			}else
				return false;
		});

		outputLoader = new OutputLoader;
		outputLoader.each((c){
			choiceFilter.addChoice(c);
			synchronized(this){
				if(c.score >= 10000*999)
					output = c ~ output;
				else
					output ~= c;
			}
		});

		reset;
		resetChoices;
		resetFilter;
	}

	void reset(){
		command = [""];
		editing = 0;
		cursor = 0;
		filterText = "";
		commandSelected = null;
		commandHistory = false;
		choiceFilter.reset("");
	}

	void resetFilter(){
		choiceFilter.reset(text);
		selected = -1;
	}

	void resetChoices(){
		bashCompletions = [];
		synchronized(this)
			choiceFilter.setChoices(output);

		if(execLoader)
			execLoader.stop;
		execLoader = new ExecutablesLoader;
		execLoader.each(&choiceFilter.addChoice);

		if(processLoader)
			processLoader.stop;
		processLoader = new TalkProcessLoader;
		processLoader.each(&choiceFilter.addChoice);

		scannedDirs = [getcwd];
		if(filesLoader)
			filesLoader.stop;
		filesLoader = new FilesLoader(getcwd, 2, &dirLoaded);
		filesLoader.each((c){
			if(c.type == Type.directory){
				synchronized(this){
					if(scannedDirs.canFind(c.text))
						return;
					else
						scannedDirs ~= c.text;
				}
			}
			choiceFilter.addChoice(c);
		});

		choiceFilter.start({});
		choiceFilter.reset(text);
	}

	void resetState(){
		if(editing != 0){
			commandHistory = false;
			filterText = "";
		}
	}

	void checkNativeCompletions(){
		auto dirty = bashCompletions.length > 0;
		bashCompletions = [];
		if(command.length > 1){
			foreach(c; loadParams(toString))
				bashCompletions ~= new CommandBashCompletion(c);
			if(bashCompletions.length)
				choiceFilter.setChoices(bashCompletions);
		}
		if(dirty)
			resetChoices;
	}

	string finishedPart(){
		return reduce!"a ~ ' ' ~ b"("", command[0..editing]);
	}

	void clearOutput(){
		std.file.write(options.configPath ~ ".log", "");
		output = [];
	}

	void run(bool r=true){
		if(!command[0].length)
			return;
		if(!commandSelected){
			auto res = choiceFilter.res;
			if(res.length && selected >= -1)
				commandSelected = res[selected<0 ? 0 : selected].data;
			else
				commandSelected = new CommandExec(command[0]);
		}
		commandSelected.parameter = "";
		if(command.length > 1)
			commandSelected.parameter = command[1..$].reduce!"a ~ ' ' ~ b";
		commandSelected.run;
		if(r){
			reset;
			resetChoices;
		}
	}

	void select(long selected){
		auto res = choiceFilter.res;
		selected = max(-cast(long)output.length-1, min(res.length-1, selected));
		if(selected == -1){
			if(filterText.length){
				text = filterText[0..$-1];
				cursor = text.length;
				filterText = "";
				if(editing == 0)
					commandSelected = null;
			}
		}else if(selected > -1){
			selectChoice(selected);
		}else{
			selectOutput(-selected-2);
		}
		this.selected = selected;
	}

	void selectChoice(long selected){
		if(!filterText.length)
			filterText = text ~ ' ';
		auto res = choiceFilter.res;
		if(this.selected < selected){
			if(!res.length && !commandHistory){
				commandHistory = true;
				resetFilter;
				return;
			}
		}
		if(selected < res.length){
			auto sel = res[cast(size_t)selected].data;
			if(editing == 0 || commandHistory){
				if(sel.type == Type.history)
					commandSelected = (cast(CommandHistory)sel).command;
				else
					commandSelected = sel;
				if(commandHistory){
					command = [commandSelected.text];
					if(sel.parameter.length)
						command ~= sel.parameter;
					editing = command.length-1;
				}else{
					command[0] = commandSelected.text;
				}
			}else{
				text = sel.text;
			}
			cursor = text.length;
		}
	}

	void selectOutput(long selected){
		if(!filterText.length)
			filterText = text ~ ' ';
		auto c = output[cast(size_t)selected];
		if(c.parameter.length)
			text = c.parameter;
		else
			text = '\'' ~ c.text ~ '\'';
		cursor = text.length;
	}

	// Text functions

	ref string text(){
		return command[editing];
	}

	void moveLeft(bool word=false){
		if(editing && cursor == 0){
			commandHistory = false;
			editing--;
			cursor = command[editing].length;
			if(editing == 0){
				commandSelected = null;
			}
			resetFilter;
		}else if(!word)
			cursor = max(0, cast(long)cursor-1);
	}

	void moveRight(bool word=false){
		if(cursor == text.length && text.length && editing+1 < command.length){
			resetState;
			if(editing == 0 && !commandSelected)
				select(0);
			editing++;
			cursor = 0;
			selected = -1;
			resetFilter;
			commandHistory = false;
		}else if(!word)
			cursor = min(cursor+1, text.length);
	}
	
	// Text altering

	void insert(string s){
		filterText = "";
		if(cursor == text.length && s == " " && (cursor<2 || text[cursor-2] != '\\')){
			if(!commandSelected && editing == 0){
				auto res = choiceFilter.res;
				if(res.length && selected >= -1)
					commandSelected = res[selected<0 ? 0 : selected].data;
				else
					commandSelected = new CommandExec(command[0]);
				text = commandSelected.text;
			}
			command ~= "";
			editing++;
			cursor = 0;
			choiceFilter.reset;
			select(-1);
			checkNativeCompletions;
			return;
		}

		if(editing == 0){
			commandSelected = null;
			filterText = "";
		}
		if(!text.length)
			choiceFilter.reset;
		text = text[0..cursor] ~ s ~ text[cursor..$];
		cursor += s.length;
		choiceFilter.narrow(s);
		select(-1);

		checkNativeCompletions;

		auto dir = text.expandTilde.buildNormalizedPath.unixClean;
		if(dir.exists && dir.isDir && !scannedDirs.canFind(dir)){
			filesLoader.postLoad(dir, 0);
		}

	}

	void deleteLeft(){
		reset;
		resetChoices;
		select(-1);
		checkNativeCompletions;
	}

	void delChar(){
		resetState;
		text.delChar(cursor);
		resetFilter;
		select(-1);
		checkNativeCompletions;
	}

	void delBackChar(){
		resetState;
		if(cursor == 0 && command.length && editing > 0){
			command = command[0..editing] ~ command[editing+1..$];
			moveLeft;
			return;
		}
		text.delBackChar(cursor);
		resetFilter;
		select(-1);
		checkNativeCompletions;
	}

	void deleteWordLeft(){
		resetState;
		if(cursor == 0 && command.length && editing > 0){
			command = command[0..editing] ~ command[editing+1..$];
			moveLeft;
		}
		text.deleteWordLeft(cursor);
		resetFilter;
		select(-1);
		checkNativeCompletions;
	}

	void deleteWordRight(){
		resetState;
		text.deleteWordRight(cursor);
		resetFilter;
		select(-1);
		checkNativeCompletions;
	}

	override string toString(){
		if(commandSelected){
			if(command.length > 1)
				return commandSelected.text ~ ' ' ~ reduce!"a ~ ' ' ~ b"("", command[1..$]);
			else
				return commandSelected.text;
		}
		if(command.length)
			return command.reduce!"a ~ ' ' ~ b";
		return "";
	}

	protected:

		bool dirLoaded(string s){
			synchronized(this){
				if(scannedDirs.canFind(s))
					return true;
				scannedDirs ~= s;
				return false;
			}
		}


}