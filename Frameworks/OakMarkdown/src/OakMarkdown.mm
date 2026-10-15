#import "OakMarkdown.h"

NSAttributedStringKey const OakMarkdownCodeBlockAttributeName = @"OakMarkdownCodeBlock";

static CGFloat const kListIndent  = 18;
static CGFloat const kQuoteIndent = 12;

@implementation OakMarkdownStyle
+ (instancetype)defaultStyle
{
	OakMarkdownStyle* style = [[self alloc] init];
	style.font                = [NSFont systemFontOfSize:NSFont.systemFontSize];
	style.codeFont            = [NSFont monospacedSystemFontOfSize:NSFont.systemFontSize - 1 weight:NSFontWeightRegular];
	style.textColor           = NSColor.labelColor;
	style.secondaryTextColor  = NSColor.secondaryLabelColor;
	style.codeBackgroundColor = [NSColor.labelColor colorWithAlphaComponent:0.06];
	style.borderColor         = NSColor.separatorColor;
	return style;
}
@end

@interface OakMarkdownCodeBlock ()
@property (nonatomic, readwrite) NSString* code;
@property (nonatomic, readwrite) NSString* language;
@end

@implementation OakMarkdownCodeBlock
@end

namespace
{
	// The intent chain of a run, innermost first, with the facts we need
	struct block_info_t
	{
		block_info_t (NSPresentationIntent* intent)
		{
			for(NSPresentationIntent* it = intent; it; it = it.parentIntent)
			{
				switch(it.intentKind)
				{
					case NSPresentationIntentKindHeader:         headerLevel = it.headerLevel;                 break;
					case NSPresentationIntentKindCodeBlock:      codeBlock = it;                               break;
					case NSPresentationIntentKindBlockQuote:     ++quoteDepth;                                 break;
					case NSPresentationIntentKindOrderedList:
					case NSPresentationIntentKindUnorderedList:  ++listDepth; if(!list) list = it;             break;
					case NSPresentationIntentKindListItem:       if(!listItem) listItem = it;                  break;
					case NSPresentationIntentKindTable:          table = it;                                   break;
					case NSPresentationIntentKindTableHeaderRow: tableRow = it; headerRow = true;              break;
					case NSPresentationIntentKindTableRow:       tableRow = it;                                break;
					case NSPresentationIntentKindTableCell:      tableCell = it;                               break;
					case NSPresentationIntentKindThematicBreak:  thematicBreak = true;                         break;
					default:                                                                                   break;
				}
			}
			identity = intent ? intent.identity : NSNotFound;
		}

		NSInteger identity = NSNotFound;
		NSInteger headerLevel = 0;
		NSInteger quoteDepth = 0;
		NSInteger listDepth = 0;
		NSPresentationIntent* list = nil;
		NSPresentationIntent* listItem = nil;
		NSPresentationIntent* codeBlock = nil;
		NSPresentationIntent* table = nil;
		NSPresentationIntent* tableRow = nil;
		NSPresentationIntent* tableCell = nil;
		bool headerRow = false;
		bool thematicBreak = false;
	};

	struct renderer_t
	{
		renderer_t (OakMarkdownStyle* style, NSAttributedString*(^footer)(NSUInteger)) : style(style), footer(footer)
		{
			output     = [[NSMutableAttributedString alloc] init];
			codeBlocks = [NSMutableArray array];
			tables     = [NSMutableDictionary dictionary];
			tableRows  = [NSMutableDictionary dictionary];
		}

		void append_run (NSString* text, NSDictionary* attributes)
		{
			block_info_t block(attributes[NSPresentationIntentAttributeName]);

			if(block.identity != lastIdentity)
			{
				finish_code_block_if_needed(block);
				if(output.length)
					append(@"\n", @{ NSParagraphStyleAttributeName: paragraphStyle });
				begin_block(block);
				lastIdentity = block.identity;
			}

			if(block.codeBlock)
			{
				// The parser includes the fence’s trailing newline; we add our own separators
				if([text hasSuffix:@"\n"])
					text = [text substringToIndex:text.length - 1];
				[currentCode appendString:text];
			}

			append(text, inline_attributes(attributes, block));
		}

		NSAttributedString* finish ()
		{
			finish_code_block_if_needed(block_info_t(nil));
			return output;
		}

		NSMutableArray<OakMarkdownCodeBlock*>* codeBlocks;

	private:
		void append (NSString* text, NSDictionary* attributes)
		{
			[output appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
		}

		void begin_block (block_info_t const& block)
		{
			NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
			paragraph.paragraphSpacing = 6;

			CGFloat indent = block.quoteDepth * kQuoteIndent;
			NSString* prefix = nil;

			if(block.listItem)
			{
				indent += block.listDepth * kListIndent;
				paragraph.paragraphSpacing = 3;
				if(block.listItem.identity != lastListItemIdentity)
				{
					lastListItemIdentity = block.listItem.identity;
					prefix = block.list.intentKind == NSPresentationIntentKindOrderedList ? [NSString stringWithFormat:@"%ld.\t", block.listItem.ordinal] : @"•\t";
					paragraph.firstLineHeadIndent = indent - kListIndent;
				}
				else
				{
					paragraph.firstLineHeadIndent = indent; // further paragraphs of the same item
				}
				paragraph.tabStops = @[ [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:indent options:@{ }] ];
				paragraph.headIndent = indent;
			}
			else
			{
				paragraph.firstLineHeadIndent = indent;
				paragraph.headIndent          = indent;
			}

			if(block.headerLevel)
			{
				paragraph.paragraphSpacingBefore = 6;
				paragraph.paragraphSpacing       = 4;
			}

			if(block.codeBlock && block.codeBlock.identity != currentCodeIdentity)
			{
				currentCodeIdentity = block.codeBlock.identity;
				currentCode         = [NSMutableString string];
				currentLanguage     = block.codeBlock.languageHint.length ? block.codeBlock.languageHint : nil;

				codeTextBlock = [[NSTextBlock alloc] init];
				codeTextBlock.backgroundColor = style.codeBackgroundColor;
				[codeTextBlock setValue:100 type:NSTextBlockPercentageValueType forDimension:NSTextBlockWidth];
				[codeTextBlock setWidth:8 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
				[codeTextBlock setWidth:4 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinYEdge];
				[codeTextBlock setWidth:4 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMaxYEdge];
				[codeTextBlock setWidth:indent type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];
			}

			if(block.codeBlock)
			{
				paragraph.textBlocks       = @[ codeTextBlock ];
				paragraph.firstLineHeadIndent = 0;
				paragraph.headIndent       = 0;
				paragraph.paragraphSpacing = 0;
			}
			else if(block.quoteDepth && !block.listItem)
			{
				NSTextBlock* quote = [[NSTextBlock alloc] init];
				[quote setWidth:3 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder edge:NSMinXEdge];
				[quote setBorderColor:style.borderColor forEdge:NSMinXEdge];
				[quote setWidth:8 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:NSMinXEdge];
				[quote setWidth:(block.quoteDepth - 1) * kQuoteIndent type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];
				paragraph.textBlocks          = @[ quote ];
				paragraph.firstLineHeadIndent = 0;
				paragraph.headIndent          = 0;
			}

			if(block.tableCell)
			{
				NSNumber* tableKey = @(block.table.identity);
				NSTextTable* table = tables[tableKey];
				if(!table)
				{
					table = [[NSTextTable alloc] init];
					table.numberOfColumns = MAX(block.table.columnCount, 1);
					table.layoutAlgorithm = NSTextTableAutomaticLayoutAlgorithm;
					table.collapsesBorders = YES;
					tables[tableKey] = table;
				}

				// Row index by order of appearance, so it doesn’t matter how the parser numbers rows
				NSMutableArray* rows = tableRows[tableKey] ?: (tableRows[tableKey] = [NSMutableArray array]);
				if(![rows containsObject:@(block.tableRow.identity)])
					[rows addObject:@(block.tableRow.identity)];
				NSInteger row = [rows indexOfObject:@(block.tableRow.identity)];

				NSTextTableBlock* cell = [[NSTextTableBlock alloc] initWithTable:table startingRow:row rowSpan:1 startingColumn:block.tableCell.column columnSpan:1];
				[cell setWidth:0.5 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder];
				[cell setBorderColor:style.borderColor];
				[cell setWidth:4 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
				paragraph.textBlocks          = @[ cell ];
				paragraph.firstLineHeadIndent = 0;
				paragraph.headIndent          = 0;
				paragraph.paragraphSpacing    = 0;
			}

			paragraphStyle = paragraph;

			if(block.thematicBreak)
				append(@"⸻", @{ NSParagraphStyleAttributeName: paragraph, NSForegroundColorAttributeName: style.secondaryTextColor, NSFontAttributeName: style.font });
			if(prefix)
				append(prefix, @{ NSParagraphStyleAttributeName: paragraph, NSForegroundColorAttributeName: style.textColor, NSFontAttributeName: style.font });
		}

		void finish_code_block_if_needed (block_info_t const& next)
		{
			if(!currentCode || (next.codeBlock && next.codeBlock.identity == currentCodeIdentity))
				return;

			OakMarkdownCodeBlock* codeBlock = [[OakMarkdownCodeBlock alloc] init];
			codeBlock.code     = currentCode;
			codeBlock.language = currentLanguage;
			[codeBlocks addObject:codeBlock];

			if(footer)
			{
				if(NSAttributedString* str = footer(codeBlocks.count - 1))
				{
					NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
					paragraph.paragraphSpacing = 6;
					paragraph.firstLineHeadIndent = paragraph.headIndent = paragraphStyle.headIndent;
					append(@"\n", @{ NSParagraphStyleAttributeName: paragraphStyle });
					NSMutableAttributedString* footerString = [str mutableCopy];
					[footerString addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, footerString.length)];
					[output appendAttributedString:footerString];
					paragraphStyle = paragraph;
				}
			}

			currentCode         = nil;
			currentLanguage     = nil;
			currentCodeIdentity = NSNotFound;
		}

		NSDictionary* inline_attributes (NSDictionary* attributes, block_info_t const& block)
		{
			NSUInteger inlineIntent = [attributes[NSInlinePresentationIntentAttributeName] unsignedIntegerValue];
			NSFontManager* fm = NSFontManager.sharedFontManager;

			NSFont* font = style.font;
			if(block.codeBlock || (inlineIntent & NSInlinePresentationIntentCode))
				font = style.codeFont;
			if(block.headerLevel)
				font = [NSFont systemFontOfSize:style.font.pointSize + std::max<NSInteger>(0, 8 - 2 * block.headerLevel) weight:NSFontWeightSemibold];
			if((inlineIntent & NSInlinePresentationIntentStronglyEmphasized) || block.headerRow)
				font = [fm convertFont:font toHaveTrait:NSBoldFontMask];
			if(inlineIntent & NSInlinePresentationIntentEmphasized)
				font = [fm convertFont:font toHaveTrait:NSItalicFontMask];

			NSMutableDictionary* res = [NSMutableDictionary dictionaryWithDictionary:@{
				NSFontAttributeName:            font,
				NSForegroundColorAttributeName: block.quoteDepth ? style.secondaryTextColor : style.textColor,
				NSParagraphStyleAttributeName:  paragraphStyle,
			}];

			if(block.codeBlock)
				res[OakMarkdownCodeBlockAttributeName] = @(codeBlocks.count);
			else if(inlineIntent & NSInlinePresentationIntentCode)
				res[NSBackgroundColorAttributeName] = style.codeBackgroundColor;
			if(inlineIntent & NSInlinePresentationIntentStrikethrough)
				res[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
			if(id link = attributes[NSLinkAttributeName])
				res[NSLinkAttributeName] = link;
			return res;
		}

		OakMarkdownStyle* style;
		NSAttributedString*(^footer)(NSUInteger);
		NSMutableAttributedString* output;
		NSParagraphStyle* paragraphStyle = [NSParagraphStyle defaultParagraphStyle];

		NSInteger lastIdentity         = NSNotFound - 1;
		NSInteger lastListItemIdentity = NSNotFound;

		NSInteger currentCodeIdentity = NSNotFound;
		NSMutableString* currentCode;
		NSString* currentLanguage;
		NSTextBlock* codeTextBlock;

		NSMutableDictionary<NSNumber*, NSTextTable*>* tables;
		NSMutableDictionary<NSNumber*, NSMutableArray*>* tableRows;
	};
}

@implementation OakMarkdownRenderer
+ (NSAttributedString*)attributedStringFromMarkdown:(NSString*)markdown style:(OakMarkdownStyle*)style codeBlocks:(NSArray<OakMarkdownCodeBlock*>**)codeBlocks codeBlockFooter:(NSAttributedString*(^)(NSUInteger index))codeBlockFooter
{
	NSAttributedStringMarkdownParsingOptions* options = [[NSAttributedStringMarkdownParsingOptions alloc] init];
	options.interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxFull;
	options.failurePolicy     = NSAttributedStringMarkdownParsingFailureReturnPartiallyParsedIfPossible;

	style = style ?: [OakMarkdownStyle defaultStyle];
	renderer_t renderer(style, codeBlockFooter);
	renderer_t* rendererPtr = &renderer; // blocks would capture the C++ object by copy

	NSAttributedString* parsed = [[NSAttributedString alloc] initWithMarkdownString:markdown options:options baseURL:nil error:nil];
	if(!parsed)
	{
		if(codeBlocks)
			*codeBlocks = @[ ];
		return [[NSAttributedString alloc] initWithString:markdown attributes:@{ NSFontAttributeName: style.font, NSForegroundColorAttributeName: style.textColor }];
	}

	[parsed enumerateAttributesInRange:NSMakeRange(0, parsed.length) options:0 usingBlock:^(NSDictionary<NSAttributedStringKey, id>* attributes, NSRange range, BOOL* stop){
		rendererPtr->append_run([parsed.string substringWithRange:range], attributes);
	}];

	NSAttributedString* res = renderer.finish();
	if(codeBlocks)
		*codeBlocks = [renderer.codeBlocks copy];
	return res;
}
@end
