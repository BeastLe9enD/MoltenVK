/*
 * MVKRenderPass.mm
 *
 * Copyright (c) 2015-2022 The Brenwill Workshop Ltd. (http://www.brenwill.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "MVKRenderPass.h"
#include "MVKFramebuffer.h"
#include "MVKCommandBuffer.h"
#include "MVKCommandEncodingPool.h"
#include "MVKFoundation.h"
#include "mvk_datatypes.hpp"
#include "MTLRenderPassDepthAttachmentDescriptor+MoltenVK.h"
#if MVK_MACOS_OR_IOS
#include "MTLRenderPassStencilAttachmentDescriptor+MoltenVK.h"
#endif
#include <cassert>

using namespace std;


#pragma mark -
#pragma mark MVKRenderSubpass

MVKVulkanAPIObject* MVKRenderSubpass::getVulkanAPIObject() { return _renderPass->getVulkanAPIObject(); };

bool MVKRenderSubpass::hasColorAttachments() {
	for (auto& ca : _colorAttachments) {
		if (ca.attachment != VK_ATTACHMENT_UNUSED) { return true; }
	}
	return false;
}

VkFormat MVKRenderSubpass::getColorAttachmentFormat(uint32_t colorAttIdx) {
	if (colorAttIdx < _colorAttachments.size()) {
		uint32_t rpAttIdx = _colorAttachments[colorAttIdx].attachment;
		if (rpAttIdx == VK_ATTACHMENT_UNUSED) { return VK_FORMAT_UNDEFINED; }
		return _renderPass->_attachments[rpAttIdx].getFormat();
	}
	return VK_FORMAT_UNDEFINED;
}

bool MVKRenderSubpass::isColorAttachmentUsed(uint32_t colorAttIdx) {
	if (colorAttIdx >= _colorAttachments.size()) {
		return false;
	}
	return _colorAttachments[colorAttIdx].attachment != VK_ATTACHMENT_UNUSED;
}


bool MVKRenderSubpass::isColorAttachmentAlsoInputAttachment(uint32_t colorAttIdx) {
	if (colorAttIdx >= _colorAttachments.size()) { return false; }

	uint32_t rspAttIdx = _colorAttachments[colorAttIdx].attachment;
	if (rspAttIdx == VK_ATTACHMENT_UNUSED) { return false; }

	for (auto& inAtt : _inputAttachments) {
		if (inAtt.attachment == rspAttIdx) { return true; }
	}
	return false;
}

VkFormat MVKRenderSubpass::getDepthStencilFormat() {
	uint32_t rpAttIdx = _depthStencilAttachment.attachment;
	if (rpAttIdx == VK_ATTACHMENT_UNUSED) { return VK_FORMAT_UNDEFINED; }
	return _renderPass->_attachments[rpAttIdx].getFormat();
}

VkSampleCountFlagBits MVKRenderSubpass::getSampleCount() {
	for (auto& ca : _colorAttachments) {
		uint32_t rpAttIdx = ca.attachment;
		if (rpAttIdx != VK_ATTACHMENT_UNUSED) {
			return _renderPass->_attachments[rpAttIdx].getSampleCount();
		}
	}
	uint32_t rpAttIdx = _depthStencilAttachment.attachment;
	if (rpAttIdx != VK_ATTACHMENT_UNUSED) {
		return _renderPass->_attachments[rpAttIdx].getSampleCount();
	}

	return VK_SAMPLE_COUNT_1_BIT;
}

// Extract the first view, number of views, and the portion of the mask to be rendered from
// the lowest clump of set bits in a view mask.
static uint32_t getNextViewMaskGroup(uint32_t viewMask, uint32_t* startView, uint32_t* viewCount, uint32_t *groupMask = nullptr) {
	// First, find the first set bit. This is the start of the next clump of views to be rendered.
	// n.b. ffs(3) returns a 1-based index. This actually bit me during development of this feature.
	int pos = ffs(viewMask) - 1;
	int end = pos;
	if (groupMask) { *groupMask = 0; }
	// Now we'll step through the bits one at a time until we find a bit that isn't set.
	// This is one past the end of the next clump. Clear the bits as we go, so we can use
	// ffs(3) again on the next clump.
	// TODO: Find a way to make this faster.
	while (viewMask & (1 << end)) {
		if (groupMask) { *groupMask |= viewMask & (1 << end); }
		viewMask &= ~(1 << (end++));
	}
	if (startView) { *startView = pos; }
	if (viewCount) { *viewCount = end - pos; }
	return viewMask;
}

// Get the portion of the view mask that will be rendered in the specified Metal render pass.
uint32_t MVKRenderSubpass::getViewMaskGroupForMetalPass(uint32_t passIdx) {
	if (!_viewMask) { return 0; }
	assert(passIdx < getMultiviewMetalPassCount());
	if (!_renderPass->getPhysicalDevice()->canUseInstancingForMultiview()) {
		return 1 << getFirstViewIndexInMetalPass(passIdx);
	}
	uint32_t mask = _viewMask, groupMask = 0;
	for (uint32_t i = 0; i <= passIdx; ++i) {
		mask = getNextViewMaskGroup(mask, nullptr, nullptr, &groupMask);
	}
	return groupMask;
}

uint32_t MVKRenderSubpass::getMultiviewMetalPassCount() const {
	if (!_viewMask) { return 0; }
	if (!_renderPass->getPhysicalDevice()->canUseInstancingForMultiview()) {
		// If we can't use instanced drawing for this, we'll have to unroll the render pass.
		return __builtin_popcount(_viewMask);
	}
	uint32_t mask = _viewMask;
	uint32_t count;
	// Step through each clump until there are no more clumps. I'll know this has
	// happened when the mask becomes 0, since getNextViewMaskGroup() clears each group of bits
	// as it finds them, and returns the remainder of the mask.
	for (count = 0; mask != 0; ++count) {
		mask = getNextViewMaskGroup(mask, nullptr, nullptr);
	}
	return count;
}

uint32_t MVKRenderSubpass::getFirstViewIndexInMetalPass(uint32_t passIdx) const {
	if (!_viewMask) { return 0; }
	assert(passIdx < getMultiviewMetalPassCount());
	uint32_t mask = _viewMask;
	uint32_t startView = 0, viewCount = 0;
	if (!_renderPass->getPhysicalDevice()->canUseInstancingForMultiview()) {
		for (uint32_t i = 0; mask != 0; ++i) {
			mask = getNextViewMaskGroup(mask, &startView, &viewCount);
			while (passIdx-- > 0 && viewCount-- > 0) {
				startView++;
			}
		}
	} else {
		for (uint32_t i = 0; i <= passIdx; ++i) {
			mask = getNextViewMaskGroup(mask, &startView, nullptr);
		}
	}
	return startView;
}

uint32_t MVKRenderSubpass::getViewCountInMetalPass(uint32_t passIdx) const {
	if (!_viewMask) { return 0; }
	assert(passIdx < getMultiviewMetalPassCount());
	if (!_renderPass->getPhysicalDevice()->canUseInstancingForMultiview()) {
		return 1;
	}
	uint32_t mask = _viewMask;
	uint32_t viewCount = 0;
	for (uint32_t i = 0; i <= passIdx; ++i) {
		mask = getNextViewMaskGroup(mask, nullptr, &viewCount);
	}
	return viewCount;
}

uint32_t MVKRenderSubpass::getViewCountUpToMetalPass(uint32_t passIdx) const {
	if (!_viewMask) { return 0; }
	if (!_renderPass->getPhysicalDevice()->canUseInstancingForMultiview()) {
		return passIdx+1;
	}
	uint32_t mask = _viewMask;
	uint32_t totalViewCount = 0;
	for (uint32_t i = 0; i <= passIdx; ++i) {
		uint32_t viewCount;
		mask = getNextViewMaskGroup(mask, nullptr, &viewCount);
		totalViewCount += viewCount;
	}
	return totalViewCount;
}

void MVKRenderSubpass::populateMTLRenderPassDescriptor(MTLRenderPassDescriptor* mtlRPDesc,
													   uint32_t passIdx,
													   MVKFramebuffer* framebuffer,
													   const MVKArrayRef<MVKImageView*> attachments,
													   const MVKArrayRef<VkClearValue> clearValues,
													   bool isRenderingEntireAttachment,
													   bool loadOverride) {
	MVKPixelFormats* pixFmts = _renderPass->getPixelFormats();

	// Populate the Metal color attachments
	uint32_t caCnt = getColorAttachmentCount();
	uint32_t caUsedCnt = 0;
	for (uint32_t caIdx = 0; caIdx < caCnt; caIdx++) {
		uint32_t clrRPAttIdx = _colorAttachments[caIdx].attachment;
        if (clrRPAttIdx != VK_ATTACHMENT_UNUSED) {
			++caUsedCnt;
            MTLRenderPassColorAttachmentDescriptor* mtlColorAttDesc = mtlRPDesc.colorAttachments[caIdx];

            // If it exists, configure the resolve attachment first,
            // as it affects the store action of the color attachment.
            uint32_t rslvRPAttIdx = _resolveAttachments.empty() ? VK_ATTACHMENT_UNUSED : _resolveAttachments[caIdx].attachment;
            bool hasResolveAttachment = (rslvRPAttIdx != VK_ATTACHMENT_UNUSED);
			bool canResolveFormat = true;
			if (hasResolveAttachment) {
				MVKImageView* raImgView = attachments[rslvRPAttIdx];
				canResolveFormat = mvkAreAllFlagsEnabled(pixFmts->getCapabilities(raImgView->getMTLPixelFormat()), kMVKMTLFmtCapsResolve);
				if (canResolveFormat) {
					raImgView->populateMTLRenderPassAttachmentDescriptorResolve(mtlColorAttDesc);

					// In a multiview render pass, we need to override the starting layer to ensure
					// only the enabled views are loaded.
					if (isMultiview()) {
						uint32_t startView = getFirstViewIndexInMetalPass(passIdx);
						if (mtlColorAttDesc.resolveTexture.textureType == MTLTextureType3D)
							mtlColorAttDesc.resolveDepthPlane += startView;
						else
							mtlColorAttDesc.resolveSlice += startView;
					}
				}
			}

            // Configure the color attachment
            MVKRenderPassAttachment* clrMVKRPAtt = &_renderPass->_attachments[clrRPAttIdx];
			if (clrMVKRPAtt->populateMTLRenderPassAttachmentDescriptor(mtlColorAttDesc, this, attachments[clrRPAttIdx],
                                                                       isRenderingEntireAttachment,
                                                                       hasResolveAttachment, canResolveFormat,
																	   false, loadOverride)) {
				mtlColorAttDesc.clearColor = pixFmts->getMTLClearColor(clearValues[clrRPAttIdx], clrMVKRPAtt->getFormat());
			}
			if (isMultiview()) {
				uint32_t startView = getFirstViewIndexInMetalPass(passIdx);
				if (mtlColorAttDesc.texture.textureType == MTLTextureType3D)
					mtlColorAttDesc.depthPlane += startView;
				else
					mtlColorAttDesc.slice += startView;
			}
		}
	}

	// Populate the Metal depth and stencil attachments
	uint32_t dsRPAttIdx = _depthStencilAttachment.attachment;
	uint32_t dsRslvRPAttIdx = _depthStencilResolveAttachment.attachment;
	if (dsRPAttIdx != VK_ATTACHMENT_UNUSED) {
		MVKRenderPassAttachment* dsMVKRPAtt = &_renderPass->_attachments[dsRPAttIdx];
		MVKImageView* dsImage = attachments[dsRPAttIdx];
		MVKImageView* dsRslvImage = nullptr;
		MTLPixelFormat mtlDSFormat = dsImage->getMTLPixelFormat(0);

		if (dsRslvRPAttIdx != VK_ATTACHMENT_UNUSED) {
			dsRslvImage = attachments[dsRslvRPAttIdx];
		}

		if (pixFmts->isDepthFormat(mtlDSFormat)) {
			MTLRenderPassDepthAttachmentDescriptor* mtlDepthAttDesc = mtlRPDesc.depthAttachment;
			bool hasResolveAttachment = (dsRslvRPAttIdx != VK_ATTACHMENT_UNUSED && _depthResolveMode != VK_RESOLVE_MODE_NONE);
			if (hasResolveAttachment) {
				dsRslvImage->populateMTLRenderPassAttachmentDescriptorResolve(mtlDepthAttDesc);
				mtlDepthAttDesc.depthResolveFilterMVK = mvkMTLMultisampleDepthResolveFilterFromVkResolveModeFlagBits(_depthResolveMode);
				if (isMultiview()) {
					mtlDepthAttDesc.resolveSlice += getFirstViewIndexInMetalPass(passIdx);
				}
			}
			if (dsMVKRPAtt->populateMTLRenderPassAttachmentDescriptor(mtlDepthAttDesc, this, dsImage,
                                                                      isRenderingEntireAttachment,
                                                                      hasResolveAttachment, true,
																	  false, loadOverride)) {
                mtlDepthAttDesc.clearDepth = pixFmts->getMTLClearDepthValue(clearValues[dsRPAttIdx]);
			}
			if (isMultiview()) {
				mtlDepthAttDesc.slice += getFirstViewIndexInMetalPass(passIdx);
			}
		}
		if (pixFmts->isStencilFormat(mtlDSFormat)) {
			MTLRenderPassStencilAttachmentDescriptor* mtlStencilAttDesc = mtlRPDesc.stencilAttachment;
			bool hasResolveAttachment = (dsRslvRPAttIdx != VK_ATTACHMENT_UNUSED && _stencilResolveMode != VK_RESOLVE_MODE_NONE);
			if (hasResolveAttachment) {
				dsRslvImage->populateMTLRenderPassAttachmentDescriptorResolve(mtlStencilAttDesc);
#if MVK_MACOS_OR_IOS
				mtlStencilAttDesc.stencilResolveFilterMVK = mvkMTLMultisampleStencilResolveFilterFromVkResolveModeFlagBits(_stencilResolveMode);
#endif
				if (isMultiview()) {
					mtlStencilAttDesc.resolveSlice += getFirstViewIndexInMetalPass(passIdx);
				}
			}
			if (dsMVKRPAtt->populateMTLRenderPassAttachmentDescriptor(mtlStencilAttDesc, this, dsImage,
                                                                      isRenderingEntireAttachment,
                                                                      hasResolveAttachment, true,
																	  true, loadOverride)) {
				mtlStencilAttDesc.clearStencil = pixFmts->getMTLClearStencilValue(clearValues[dsRPAttIdx]);
			}
			if (isMultiview()) {
				mtlStencilAttDesc.slice += getFirstViewIndexInMetalPass(passIdx);
			}
		}
	}

	// Vulkan supports rendering without attachments, but older Metal does not.
	// If Metal does not support rendering without attachments, create a dummy attachment to pass Metal validation.
	if (caUsedCnt == 0 && dsRPAttIdx == VK_ATTACHMENT_UNUSED) {
        if (_renderPass->getDevice()->_pMetalFeatures->renderWithoutAttachments) {
#if MVK_MACOS_OR_IOS
            mtlRPDesc.defaultRasterSampleCount = mvkSampleCountFromVkSampleCountFlagBits(_defaultSampleCount);
#endif
		} else {
			MTLRenderPassColorAttachmentDescriptor* mtlColorAttDesc = mtlRPDesc.colorAttachments[0];
			mtlColorAttDesc.texture = framebuffer->getDummyAttachmentMTLTexture(this, passIdx);
			mtlColorAttDesc.level = 0;
			mtlColorAttDesc.slice = 0;
			mtlColorAttDesc.depthPlane = 0;
			mtlColorAttDesc.loadAction = MTLLoadActionDontCare;
			mtlColorAttDesc.storeAction = MTLStoreActionDontCare;
		}
	}
}

void MVKRenderSubpass::encodeStoreActions(MVKCommandEncoder* cmdEncoder,
                                          bool isRenderingEntireAttachment,
										  const MVKArrayRef<MVKImageView*> attachments,
                                          bool storeOverride) {
    if (!cmdEncoder->_mtlRenderEncoder) { return; }
	if (!_renderPass->getDevice()->_pMetalFeatures->deferredStoreActions) { return; }

	MVKPixelFormats* pixFmts = _renderPass->getPixelFormats();
    uint32_t caCnt = getColorAttachmentCount();
    for (uint32_t caIdx = 0; caIdx < caCnt; ++caIdx) {
        uint32_t clrRPAttIdx = _colorAttachments[caIdx].attachment;
        if (clrRPAttIdx != VK_ATTACHMENT_UNUSED) {
			uint32_t rslvRPAttIdx = _resolveAttachments.empty() ? VK_ATTACHMENT_UNUSED : _resolveAttachments[caIdx].attachment;
			bool hasResolveAttachment = (rslvRPAttIdx != VK_ATTACHMENT_UNUSED);
			bool canResolveFormat = hasResolveAttachment && mvkAreAllFlagsEnabled(pixFmts->getCapabilities(attachments[rslvRPAttIdx]->getMTLPixelFormat()), kMVKMTLFmtCapsResolve);
			_renderPass->_attachments[clrRPAttIdx].encodeStoreAction(cmdEncoder, this, attachments[clrRPAttIdx], isRenderingEntireAttachment, hasResolveAttachment, canResolveFormat, caIdx, false, storeOverride);
        }
    }
    uint32_t dsRPAttIdx = _depthStencilAttachment.attachment;
    if (dsRPAttIdx != VK_ATTACHMENT_UNUSED) {
        bool hasResolveAttachment = _depthStencilResolveAttachment.attachment != VK_ATTACHMENT_UNUSED;
        bool hasDepthResolveAttachment = hasResolveAttachment && _depthResolveMode != VK_RESOLVE_MODE_NONE;
        bool hasStencilResolveAttachment = hasResolveAttachment && _stencilResolveMode != VK_RESOLVE_MODE_NONE;
		bool canResolveFormat = true;
        _renderPass->_attachments[dsRPAttIdx].encodeStoreAction(cmdEncoder, this, attachments[dsRPAttIdx], isRenderingEntireAttachment, hasDepthResolveAttachment, canResolveFormat, 0, false, storeOverride);
        _renderPass->_attachments[dsRPAttIdx].encodeStoreAction(cmdEncoder, this, attachments[dsRPAttIdx], isRenderingEntireAttachment, hasStencilResolveAttachment, canResolveFormat, 0, true, storeOverride);
    }
}

void MVKRenderSubpass::populateClearAttachments(MVKClearAttachments& clearAtts,
												const MVKArrayRef<VkClearValue> clearValues) {
	uint32_t attIdx;
	uint32_t caCnt = getColorAttachmentCount();
	for (uint32_t caIdx = 0; caIdx < caCnt; caIdx++) {
		attIdx = _colorAttachments[caIdx].attachment;
		if ((attIdx != VK_ATTACHMENT_UNUSED) && _renderPass->_attachments[attIdx].shouldClearAttachment(this, false)) {
			clearAtts.push_back( { VK_IMAGE_ASPECT_COLOR_BIT, caIdx, clearValues[attIdx] } );
		}
	}

	attIdx = _depthStencilAttachment.attachment;
	if (attIdx != VK_ATTACHMENT_UNUSED) {
		MVKPixelFormats* pixFmts = _renderPass->getPixelFormats();
		MTLPixelFormat mtlDSFmt = pixFmts->getMTLPixelFormat(getDepthStencilFormat());
		auto& rpAtt = _renderPass->_attachments[attIdx];
		VkImageAspectFlags aspectMask = 0;
		if (rpAtt.shouldClearAttachment(this, false) && pixFmts->isDepthFormat(mtlDSFmt)) {
			mvkEnableFlags(aspectMask, VK_IMAGE_ASPECT_DEPTH_BIT);
		}
		if (rpAtt.shouldClearAttachment(this, true) && pixFmts->isStencilFormat(mtlDSFmt)) {
			mvkEnableFlags(aspectMask, VK_IMAGE_ASPECT_STENCIL_BIT);
		}
		if (aspectMask) {
			clearAtts.push_back( { aspectMask, 0, clearValues[attIdx] } );
		}
	}
}

void MVKRenderSubpass::populateMultiviewClearRects(MVKSmallVector<VkClearRect, 1>& clearRects,
												   MVKCommandEncoder* cmdEncoder,
												   uint32_t caIdx, VkImageAspectFlags aspectMask) {
	uint32_t attIdx;
	assert(this == cmdEncoder->getSubpass());
	if (mvkIsAnyFlagEnabled(aspectMask, VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT)) {
		attIdx = _depthStencilAttachment.attachment;
		if (attIdx != VK_ATTACHMENT_UNUSED) {
			_renderPass->_attachments[attIdx].populateMultiviewClearRects(clearRects, cmdEncoder);
		}
		return;
	}
	attIdx = _colorAttachments[caIdx].attachment;
	if (attIdx != VK_ATTACHMENT_UNUSED) {
		_renderPass->_attachments[attIdx].populateMultiviewClearRects(clearRects, cmdEncoder);
	}
}

// Returns the format capabilities required by this render subpass.
// It is possible for a subpass to use a single framebuffer attachment for multiple purposes.
// For example, a subpass may use a color or depth attachment as an input attachment as well.
// So, accumulate the capabilities from all possible attachments, just to be safe.
MVKMTLFmtCaps MVKRenderSubpass::getRequiredFormatCapabilitiesForAttachmentAt(uint32_t rpAttIdx) {
	MVKMTLFmtCaps caps = kMVKMTLFmtCapsNone;

	for (auto& att : _inputAttachments) {
		if (att.attachment == rpAttIdx) {
			mvkEnableFlags(caps, kMVKMTLFmtCapsRead);
			break;
		}
	}
	for (auto& att : _colorAttachments) {
		if (att.attachment == rpAttIdx) {
			mvkEnableFlags(caps, kMVKMTLFmtCapsColorAtt);
			break;
		}
	}
	for (auto& att : _resolveAttachments) {
		if (att.attachment == rpAttIdx) {
			mvkEnableFlags(caps, kMVKMTLFmtCapsResolve);
			break;
		}
	}
	if (_depthStencilAttachment.attachment == rpAttIdx) { mvkEnableFlags(caps, kMVKMTLFmtCapsDSAtt); }
	if (_depthStencilResolveAttachment.attachment == rpAttIdx) { mvkEnableFlags(caps, kMVKMTLFmtCapsResolve); }

	return caps;
}

void MVKRenderSubpass::resolveUnresolvableAttachments(MVKCommandEncoder* cmdEncoder, const MVKArrayRef<MVKImageView*> attachments) {
	MVKPixelFormats* pixFmts = cmdEncoder->getPixelFormats();
	size_t raCnt = _resolveAttachments.size();
	for (uint32_t raIdx = 0; raIdx < raCnt; raIdx++) {
		auto& ra = _resolveAttachments[raIdx];
		auto& ca = _colorAttachments[raIdx];
		if (ra.attachment != VK_ATTACHMENT_UNUSED && ca.attachment != VK_ATTACHMENT_UNUSED) {
			MVKImageView* raImgView = attachments[ra.attachment];
			MVKImageView* caImgView = attachments[ca.attachment];

			if ( !mvkAreAllFlagsEnabled(pixFmts->getCapabilities(raImgView->getMTLPixelFormat()), kMVKMTLFmtCapsResolve) ) {
				MVKFormatType mvkFmtType = _renderPass->getPixelFormats()->getFormatType(raImgView->getMTLPixelFormat());
				id<MTLComputePipelineState> mtlRslvState = cmdEncoder->getCommandEncodingPool()->getCmdResolveColorImageMTLComputePipelineState(mvkFmtType);
				id<MTLComputeCommandEncoder> mtlComputeEnc = cmdEncoder->getMTLComputeEncoder(kMVKCommandUseResolveImage);
				[mtlComputeEnc setComputePipelineState: mtlRslvState];
				[mtlComputeEnc setTexture: raImgView->getMTLTexture() atIndex: 0];
				[mtlComputeEnc setTexture: caImgView->getMTLTexture() atIndex: 1];
				MTLSize gridSize = mvkMTLSizeFromVkExtent3D(raImgView->getExtent3D());
				MTLSize tgSize = MTLSizeMake(mtlRslvState.threadExecutionWidth, 1, 1);
				if (cmdEncoder->getDevice()->_pMetalFeatures->nonUniformThreadgroups) {
					[mtlComputeEnc dispatchThreads: gridSize threadsPerThreadgroup: tgSize];
				} else {
					MTLSize tgCount = MTLSizeMake(gridSize.width / tgSize.width, gridSize.height, gridSize.depth);
					if (gridSize.width % tgSize.width) { tgCount.width += 1; }
					[mtlComputeEnc dispatchThreadgroups: tgCount threadsPerThreadgroup: tgSize];
				}
			}
		}
	}
}

MVKRenderSubpass::MVKRenderSubpass(MVKRenderPass* renderPass,
								   const VkSubpassDescription* pCreateInfo,
								   const VkRenderPassInputAttachmentAspectCreateInfo* pInputAspects,
								   uint32_t viewMask) {
	_renderPass = renderPass;
	_subpassIndex = (uint32_t)_renderPass->_subpasses.size();
	_viewMask = viewMask;

	// Add attachments
	_inputAttachments.reserve(pCreateInfo->inputAttachmentCount);
	for (uint32_t i = 0; i < pCreateInfo->inputAttachmentCount; i++) {
		const VkAttachmentReference& att = pCreateInfo->pInputAttachments[i];
		_inputAttachments.push_back({VK_STRUCTURE_TYPE_ATTACHMENT_REFERENCE_2, nullptr, att.attachment, att.layout, 0});
	}
	if (pInputAspects && pInputAspects->aspectReferenceCount) {
		for (uint32_t i = 0; i < pInputAspects->aspectReferenceCount; i++) {
			const VkInputAttachmentAspectReference& aspectRef = pInputAspects->pAspectReferences[i];
			if (aspectRef.subpass == _subpassIndex) {
				_inputAttachments[aspectRef.inputAttachmentIndex].aspectMask = aspectRef.aspectMask;
			}
		}
	}

	_colorAttachments.reserve(pCreateInfo->colorAttachmentCount);
	for (uint32_t i = 0; i < pCreateInfo->colorAttachmentCount; i++) {
		const VkAttachmentReference& att = pCreateInfo->pColorAttachments[i];
		_colorAttachments.push_back({VK_STRUCTURE_TYPE_ATTACHMENT_REFERENCE_2, nullptr, att.attachment, att.layout, 0});
	}

	if (pCreateInfo->pResolveAttachments) {
		_resolveAttachments.reserve(pCreateInfo->colorAttachmentCount);
		for (uint32_t i = 0; i < pCreateInfo->colorAttachmentCount; i++) {
			const VkAttachmentReference& att = pCreateInfo->pResolveAttachments[i];
			_resolveAttachments.push_back({VK_STRUCTURE_TYPE_ATTACHMENT_REFERENCE_2, nullptr, att.attachment, att.layout, 0});
		}
	}

	if (pCreateInfo->pDepthStencilAttachment) {
		_depthStencilAttachment.attachment = pCreateInfo->pDepthStencilAttachment->attachment;
		_depthStencilAttachment.layout = pCreateInfo->pDepthStencilAttachment->layout;
	} else {
		_depthStencilAttachment.attachment = VK_ATTACHMENT_UNUSED;
	}

	_depthStencilResolveAttachment.attachment = VK_ATTACHMENT_UNUSED;

	_preserveAttachments.reserve(pCreateInfo->preserveAttachmentCount);
	for (uint32_t i = 0; i < pCreateInfo->preserveAttachmentCount; i++) {
		_preserveAttachments.push_back(pCreateInfo->pPreserveAttachments[i]);
	}
}

MVKRenderSubpass::MVKRenderSubpass(MVKRenderPass* renderPass,
								   const VkSubpassDescription2* pCreateInfo) {

	VkSubpassDescriptionDepthStencilResolve* pDSResolveInfo = nullptr;
	for (auto* next = (const VkBaseInStructure*)pCreateInfo->pNext; next; next = next->pNext) {
		switch (next->sType) {
		case VK_STRUCTURE_TYPE_SUBPASS_DESCRIPTION_DEPTH_STENCIL_RESOLVE:
			pDSResolveInfo = (VkSubpassDescriptionDepthStencilResolve*)next;
			break;
		default:
			break;
		}
	}

	_renderPass = renderPass;
	_subpassIndex = (uint32_t)_renderPass->_subpasses.size();
	_viewMask = pCreateInfo->viewMask;

	// Add attachments
	_inputAttachments.reserve(pCreateInfo->inputAttachmentCount);
	for (uint32_t i = 0; i < pCreateInfo->inputAttachmentCount; i++) {
		_inputAttachments.push_back(pCreateInfo->pInputAttachments[i]);
	}

	_colorAttachments.reserve(pCreateInfo->colorAttachmentCount);
	for (uint32_t i = 0; i < pCreateInfo->colorAttachmentCount; i++) {
		_colorAttachments.push_back(pCreateInfo->pColorAttachments[i]);
	}

	if (pCreateInfo->pResolveAttachments) {
		_resolveAttachments.reserve(pCreateInfo->colorAttachmentCount);
		for (uint32_t i = 0; i < pCreateInfo->colorAttachmentCount; i++) {
			_resolveAttachments.push_back(pCreateInfo->pResolveAttachments[i]);
		}
	}

	if (pCreateInfo->pDepthStencilAttachment) {
		_depthStencilAttachment = *pCreateInfo->pDepthStencilAttachment;
	} else {
		_depthStencilAttachment.attachment = VK_ATTACHMENT_UNUSED;
	}

	if (pDSResolveInfo && pDSResolveInfo->pDepthStencilResolveAttachment) {
		_depthStencilResolveAttachment = *pDSResolveInfo->pDepthStencilResolveAttachment;
		_depthResolveMode = pDSResolveInfo->depthResolveMode;
		_stencilResolveMode = pDSResolveInfo->stencilResolveMode;
	} else {
		_depthStencilResolveAttachment.attachment = VK_ATTACHMENT_UNUSED;
	}

	_preserveAttachments.reserve(pCreateInfo->preserveAttachmentCount);
	for (uint32_t i = 0; i < pCreateInfo->preserveAttachmentCount; i++) {
		_preserveAttachments.push_back(pCreateInfo->pPreserveAttachments[i]);
	}
}


#pragma mark -
#pragma mark MVKRenderPassAttachment

MVKVulkanAPIObject* MVKRenderPassAttachment::getVulkanAPIObject() { return _renderPass->getVulkanAPIObject(); };

VkFormat MVKRenderPassAttachment::getFormat() { return _info.format; }

VkSampleCountFlagBits MVKRenderPassAttachment::getSampleCount() { return _info.samples; }

bool MVKRenderPassAttachment::populateMTLRenderPassAttachmentDescriptor(MTLRenderPassAttachmentDescriptor* mtlAttDesc,
                                                                        MVKRenderSubpass* subpass,
																		MVKImageView* attachment,
                                                                        bool isRenderingEntireAttachment,
																		bool hasResolveAttachment,
																		bool canResolveFormat,
                                                                        bool isStencil,
                                                                        bool loadOverride) {
	// Populate from the attachment image view
	attachment->populateMTLRenderPassAttachmentDescriptor(mtlAttDesc);

	bool isMemorylessAttachment = false;
#if MVK_APPLE_SILICON
	isMemorylessAttachment = attachment->getMTLTexture().storageMode == MTLStorageModeMemoryless;
#endif

	// Only allow clearing of entire attachment if we're actually
	// rendering to the entire attachment AND we're in the first subpass.
	MTLLoadAction mtlLA;
	if (loadOverride || !isRenderingEntireAttachment || !isFirstUseOfAttachment(subpass)) {
		mtlLA = MTLLoadActionLoad;
    } else {
        VkAttachmentLoadOp loadOp = isStencil ? _info.stencilLoadOp : _info.loadOp;
		mtlLA = mvkMTLLoadActionFromVkAttachmentLoadOp(loadOp);
    }

	// Memoryless can be cleared, but can't be loaded, so force load to don't care.
	if (isMemorylessAttachment && mtlLA == MTLLoadActionLoad) { mtlLA = MTLLoadActionDontCare; }

	mtlAttDesc.loadAction = mtlLA;

    // If the device supports late-specified store actions, we'll use those, and then set them later.
    // That way, if we wind up doing a tessellated draw, we can set the store action to store then,
    // and then when the render pass actually ends, we can use the true store action.
    if ( _renderPass->getDevice()->_pMetalFeatures->deferredStoreActions ) {
        mtlAttDesc.storeAction = MTLStoreActionUnknown;
    } else {
		// For a combined depth-stencil format in an attachment with VK_IMAGE_ASPECT_STENCIL_BIT,
		// the attachment format may have been swizzled to a stencil-only format. In this case,
		// we want to guard against an attempt to store the non-existent depth component.
		MTLPixelFormat mtlFmt = attachment->getMTLPixelFormat();
		MVKPixelFormats* pixFmts = _renderPass->getPixelFormats();
		bool isDepthFormat = pixFmts->isDepthFormat(mtlFmt);
		bool isStencilFormat = pixFmts->isStencilFormat(mtlFmt);
		if (isStencilFormat && !isStencil && !isDepthFormat) {
			mtlAttDesc.storeAction = MTLStoreActionDontCare;
		} else {
			mtlAttDesc.storeAction = getMTLStoreAction(subpass, isRenderingEntireAttachment, isMemorylessAttachment, hasResolveAttachment, canResolveFormat, isStencil, false);
		}
    }
    return (mtlLA == MTLLoadActionClear);
}

void MVKRenderPassAttachment::encodeStoreAction(MVKCommandEncoder* cmdEncoder,
                                                MVKRenderSubpass* subpass,
												MVKImageView* attachment,
                                                bool isRenderingEntireAttachment,
												bool hasResolveAttachment,
												bool canResolveFormat,
                                                uint32_t caIdx,
                                                bool isStencil,
                                                bool storeOverride) {
	// For a combined depth-stencil format in an attachment with VK_IMAGE_ASPECT_STENCIL_BIT,
	// the attachment format may have been swizzled to a stencil-only format. In this case,
	// we want to guard against an attempt to store the non-existent depth component.
	MTLPixelFormat mtlFmt = attachment->getMTLPixelFormat();
	MVKPixelFormats* pixFmts = _renderPass->getPixelFormats();
	bool isDepthFormat = pixFmts->isDepthFormat(mtlFmt);
	bool isStencilFormat = pixFmts->isStencilFormat(mtlFmt);
	bool isColorFormat = !(isDepthFormat || isStencilFormat);

	bool isMemorylessAttachment = false;
#if MVK_APPLE_SILICON
	isMemorylessAttachment = attachment->getMTLTexture().storageMode == MTLStorageModeMemoryless;
#endif
	MTLStoreAction storeAction = getMTLStoreAction(subpass, isRenderingEntireAttachment, isMemorylessAttachment, hasResolveAttachment, canResolveFormat, isStencil, storeOverride);

	if (isColorFormat) {
		[cmdEncoder->_mtlRenderEncoder setColorStoreAction: storeAction atIndex: caIdx];
	} else if (isDepthFormat && !isStencil) {
		[cmdEncoder->_mtlRenderEncoder setDepthStoreAction: storeAction];
	} else if (isStencilFormat && isStencil) {
		[cmdEncoder->_mtlRenderEncoder setStencilStoreAction: storeAction];
	}
}

void MVKRenderPassAttachment::populateMultiviewClearRects(MVKSmallVector<VkClearRect, 1>& clearRects, MVKCommandEncoder* cmdEncoder) {
	MVKRenderSubpass* subpass = cmdEncoder->getSubpass();
	uint32_t clearMask = subpass->getViewMaskGroupForMetalPass(cmdEncoder->getMultiviewPassIndex()) & _firstUseViewMasks[subpass->_subpassIndex];

	if (!clearMask) { return; }
	VkRect2D renderArea = cmdEncoder->clipToRenderArea({{0, 0}, {kMVKUndefinedLargeUInt32, kMVKUndefinedLargeUInt32}});
	uint32_t startView, viewCount;
	do {
		clearMask = getNextViewMaskGroup(clearMask, &startView, &viewCount);
		clearRects.push_back({renderArea, startView, viewCount});
	} while (clearMask);
}

bool MVKRenderPassAttachment::isFirstUseOfAttachment(MVKRenderSubpass* subpass) {
	if ( subpass->isMultiview() ) {
		return _firstUseViewMasks[subpass->_subpassIndex] == subpass->_viewMask;
	} else {
		return _firstUseSubpassIdx == subpass->_subpassIndex;
	}
}

bool MVKRenderPassAttachment::isLastUseOfAttachment(MVKRenderSubpass* subpass) {
	if ( subpass->isMultiview() ) {
		return _lastUseViewMasks[subpass->_subpassIndex] == subpass->_viewMask;
	} else {
		return _lastUseSubpassIdx == subpass->_subpassIndex;
	}
}

MTLStoreAction MVKRenderPassAttachment::getMTLStoreAction(MVKRenderSubpass* subpass,
														  bool isRenderingEntireAttachment,
														  bool isMemorylessAttachment,
														  bool hasResolveAttachment,
														  bool canResolveFormat,
														  bool isStencil,
														  bool storeOverride) {
    // If a resolve attachment exists, this attachment must resolve once complete.
    if (hasResolveAttachment && canResolveFormat && !_renderPass->getDevice()->_pMetalFeatures->combinedStoreResolveAction) {
        return MTLStoreActionMultisampleResolve;
    }
	// Memoryless can't be stored.
	if (isMemorylessAttachment) {
		return hasResolveAttachment ? MTLStoreActionMultisampleResolve : MTLStoreActionDontCare;
	}

	// Only allow the attachment to be discarded if we're actually
	// rendering to the entire attachment and we're in the last subpass.
	if (storeOverride || !isRenderingEntireAttachment || !isLastUseOfAttachment(subpass)) {
		return hasResolveAttachment && canResolveFormat ? MTLStoreActionStoreAndMultisampleResolve : MTLStoreActionStore;
	}
	VkAttachmentStoreOp storeOp = isStencil ? _info.stencilStoreOp : _info.storeOp;
	return mvkMTLStoreActionFromVkAttachmentStoreOp(storeOp, hasResolveAttachment, canResolveFormat);
}

// If the subpass is not the first subpass to use this attachment,
// don't clear this attachment, otherwise, clear if requested.
bool MVKRenderPassAttachment::shouldClearAttachment(MVKRenderSubpass* subpass, bool isStencil) {
	if (subpass->isMultiview()) {
		if (_firstUseViewMasks[subpass->_subpassIndex] == 0) { return false; }
	} else {
		if (subpass->_subpassIndex != _firstUseSubpassIdx) { return false; }
	}
	VkAttachmentLoadOp loadOp = isStencil ? _info.stencilLoadOp : _info.loadOp;
	return loadOp == VK_ATTACHMENT_LOAD_OP_CLEAR;
}

void MVKRenderPassAttachment::validateFormat() {
	// Validate pixel format is supported
	MVKPixelFormats* pixFmts = _renderPass->getPixelFormats();
	if ( !pixFmts->isSupportedOrSubstitutable(_info.format) ) {
		_renderPass->setConfigurationResult(reportError(VK_ERROR_FORMAT_NOT_SUPPORTED, "vkCreateRenderPass(): Attachment format %s is not supported on this device.", _renderPass->getPixelFormats()->getName(_info.format)));
	}

	// Determine the indices of the first and last render subpasses to use this attachment.
	_firstUseSubpassIdx = kMVKUndefinedLargeUInt32;
	_lastUseSubpassIdx = 0;
	if ( _renderPass->isMultiview() ) {
		_firstUseViewMasks.reserve(_renderPass->_subpasses.size());
		_lastUseViewMasks.reserve(_renderPass->_subpasses.size());
	}
	for (auto& subPass : _renderPass->_subpasses) {
		// If it uses this attachment, the subpass will identify required format capabilities.
		MVKMTLFmtCaps reqCaps = subPass.getRequiredFormatCapabilitiesForAttachmentAt(_attachmentIndex);
		if (reqCaps) {
			uint32_t spIdx = subPass._subpassIndex;
			_firstUseSubpassIdx = min(spIdx, _firstUseSubpassIdx);
			_lastUseSubpassIdx = max(spIdx, _lastUseSubpassIdx);
			if ( subPass.isMultiview() ) {
				uint32_t viewMask = subPass._viewMask;
				std::for_each(_lastUseViewMasks.begin(), _lastUseViewMasks.end(), [viewMask](uint32_t& mask) { mask &= ~viewMask; });
				_lastUseViewMasks.push_back(viewMask);
				std::for_each(_firstUseViewMasks.begin(), _firstUseViewMasks.end(), [&viewMask](uint32_t mask) { viewMask &= ~mask; });
				_firstUseViewMasks.push_back(viewMask);
			}

			// Validate that the attachment pixel format supports the capabilities required by the subpass.
			// Use MTLPixelFormat to look up capabilities to permit Metal format substitution.
			// It's okay if the format does not support the resolve capability, as this can be handled via a compute shader.
			MVKMTLFmtCaps availCaps = pixFmts->getCapabilities(pixFmts->getMTLPixelFormat(_info.format));
			mvkEnableFlags(availCaps, kMVKMTLFmtCapsResolve);
			if ( !mvkAreAllFlagsEnabled(availCaps, reqCaps) ) {
				_renderPass->setConfigurationResult(reportError(VK_ERROR_FORMAT_NOT_SUPPORTED, "vkCreateRenderPass(): Attachment format %s on this device does not support the VkFormat attachment capabilities required by the subpass at index %d.", _renderPass->getPixelFormats()->getName(_info.format), spIdx));
			}
		}
	}
}

MVKRenderPassAttachment::MVKRenderPassAttachment(MVKRenderPass* renderPass,
												 const VkAttachmentDescription* pCreateInfo) {
	_info.flags = pCreateInfo->flags;
	_info.format = pCreateInfo->format;
	_info.samples = pCreateInfo->samples;
	_info.loadOp = pCreateInfo->loadOp;
	_info.storeOp = pCreateInfo->storeOp;
	_info.stencilLoadOp = pCreateInfo->stencilLoadOp;
	_info.stencilStoreOp = pCreateInfo->stencilStoreOp;
	_info.initialLayout = pCreateInfo->initialLayout;
	_info.finalLayout = pCreateInfo->finalLayout;
	_renderPass = renderPass;
	_attachmentIndex = uint32_t(_renderPass->_attachments.size());

	validateFormat();
}

MVKRenderPassAttachment::MVKRenderPassAttachment(MVKRenderPass* renderPass,
												 const VkAttachmentDescription2* pCreateInfo) {
	_info = *pCreateInfo;
	_renderPass = renderPass;
	_attachmentIndex = uint32_t(_renderPass->_attachments.size());

	validateFormat();
}


#pragma mark -
#pragma mark MVKRenderPass

VkExtent2D MVKRenderPass::getRenderAreaGranularity() {
    if (_device->_pMetalFeatures->tileBasedDeferredRendering) {
        // This is the tile area.
        // FIXME: We really ought to use MTLRenderCommandEncoder.tile{Width,Height}, but that requires
        // creating a command buffer.
        return { 32, 32 };
    }
    return { 1, 1 };
}

MVKRenderSubpass* MVKRenderPass::getSubpass(uint32_t subpassIndex) { return &_subpasses[subpassIndex]; }

bool MVKRenderPass::isMultiview() const { return _subpasses[0].isMultiview(); }

MVKRenderPass::MVKRenderPass(MVKDevice* device,
							 const VkRenderPassCreateInfo* pCreateInfo) : MVKVulkanAPIDeviceObject(device) {

	const VkRenderPassInputAttachmentAspectCreateInfo* pInputAspectCreateInfo = nullptr;
	const VkRenderPassMultiviewCreateInfo* pMultiviewCreateInfo = nullptr;
	for (auto* next = (const VkBaseInStructure*)pCreateInfo->pNext; next; next = next->pNext) {
		switch (next->sType) {
		case VK_STRUCTURE_TYPE_RENDER_PASS_INPUT_ATTACHMENT_ASPECT_CREATE_INFO:
			pInputAspectCreateInfo = (const VkRenderPassInputAttachmentAspectCreateInfo*)next;
			break;
		case VK_STRUCTURE_TYPE_RENDER_PASS_MULTIVIEW_CREATE_INFO:
			pMultiviewCreateInfo = (const VkRenderPassMultiviewCreateInfo*)next;
			break;
		default:
			break;
		}
	}

	const uint32_t* viewMasks = nullptr;
	const int32_t* viewOffsets = nullptr;
	if (pMultiviewCreateInfo && pMultiviewCreateInfo->subpassCount) {
		viewMasks = pMultiviewCreateInfo->pViewMasks;
	}
	if (pMultiviewCreateInfo && pMultiviewCreateInfo->dependencyCount) {
		viewOffsets = pMultiviewCreateInfo->pViewOffsets;
	}

    // Add subpasses and dependencies first
	_subpasses.reserve(pCreateInfo->subpassCount);
	for (uint32_t i = 0; i < pCreateInfo->subpassCount; i++) {
		_subpasses.emplace_back(this, &pCreateInfo->pSubpasses[i], pInputAspectCreateInfo, viewMasks ? viewMasks[i] : 0);
	}
	_subpassDependencies.reserve(pCreateInfo->dependencyCount);
	for (uint32_t i = 0; i < pCreateInfo->dependencyCount; i++) {
		VkSubpassDependency2 dependency = {
			.sType = VK_STRUCTURE_TYPE_SUBPASS_DEPENDENCY_2,
			.pNext = nullptr,
			.srcSubpass = pCreateInfo->pDependencies[i].srcSubpass,
			.dstSubpass = pCreateInfo->pDependencies[i].dstSubpass,
			.srcStageMask = pCreateInfo->pDependencies[i].srcStageMask,
			.dstStageMask = pCreateInfo->pDependencies[i].dstStageMask,
			.srcAccessMask = pCreateInfo->pDependencies[i].srcAccessMask,
			.dstAccessMask = pCreateInfo->pDependencies[i].dstAccessMask,
			.dependencyFlags = pCreateInfo->pDependencies[i].dependencyFlags,
			.viewOffset = viewOffsets ? viewOffsets[i] : 0,
		};
		_subpassDependencies.push_back(dependency);
	}

	// Add attachments after subpasses, so each attachment can link to subpasses
	_attachments.reserve(pCreateInfo->attachmentCount);
	for (uint32_t i = 0; i < pCreateInfo->attachmentCount; i++) {
		_attachments.emplace_back(this, &pCreateInfo->pAttachments[i]);
	}
}

MVKRenderPass::MVKRenderPass(MVKDevice* device,
							 const VkRenderPassCreateInfo2* pCreateInfo) : MVKVulkanAPIDeviceObject(device) {

    // Add subpasses and dependencies first
	_subpasses.reserve(pCreateInfo->subpassCount);
	for (uint32_t i = 0; i < pCreateInfo->subpassCount; i++) {
		_subpasses.emplace_back(this, &pCreateInfo->pSubpasses[i]);
	}
	_subpassDependencies.reserve(pCreateInfo->dependencyCount);
	for (uint32_t i = 0; i < pCreateInfo->dependencyCount; i++) {
		_subpassDependencies.push_back(pCreateInfo->pDependencies[i]);
	}

	// Add attachments after subpasses, so each attachment can link to subpasses
	_attachments.reserve(pCreateInfo->attachmentCount);
	for (uint32_t i = 0; i < pCreateInfo->attachmentCount; i++) {
		_attachments.emplace_back(this, &pCreateInfo->pAttachments[i]);
	}
}


