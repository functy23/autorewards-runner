// ==UserScript==
// @name         Microsoft Bing Rewards 自动搜索助手
// @name:en      Microsoft Bing Rewards Auto Searcher
// @namespace    WretchedSniper
// @version      1.3.2
// @description  自动完成 Microsoft Rewards 在必应（Bing）上的每日搜索任务，带有可配置的UI界面，模拟人工操作以提高安全性。目前最稳定的脚本，全自动完成电脑端90分任务。
// @description:en  Automatically completes Microsoft Rewards daily search tasks on Bing. Features a configurable UI and mimics human behavior for better safety.
// @author       WretchedSniper
// @match        *://*.bing.com/*
// @grant        none
// @run-at       document-end
// @license      MIT
// @icon         https://www.bing.com/favicon.ico
// @downloadURL https://update.greasyfork.org/scripts/538825/Microsoft%20Bing%20Rewards%20%E8%87%AA%E5%8A%A8%E6%90%9C%E7%B4%A2%E5%8A%A9%E6%89%8B.user.js
// @updateURL https://update.greasyfork.org/scripts/538825/Microsoft%20Bing%20Rewards%20%E8%87%AA%E5%8A%A8%E6%90%9C%E7%B4%A2%E5%8A%A9%E6%89%8B.meta.js
// ==/UserScript==

(function () {
    'use strict';

    // skip running inside iframes (e.g. rewards sidebar)
    if (window !== window.top) return;

    // 存储搜索词和当前进度
    let mainPageSearchTerms = []; // 主页面搜索词
    let iframeSearchTerms = []; // iframe搜索词
    let usedSearchTerms = []; // 已使用的搜索词
    let dailyTasksData = []; // 每日点击任务数据
    let currentProgress = {
        current: 0,
        total: 0,
        lastChecked: 0, // 上次检查时的进度
        completed: false, // 任务是否已完成
        noProgressCount: 0 // 连续未增加进度的次数
    };
    let isSearching = false;
    let countdownTimer = null;

    // 保底搜索词
    const fallbackSearchTerms = [
        'iPhone', 'Tesla', 'NVIDIA', 'Microsoft', 'weather', 'news today',
        'best movies', 'recipe', 'travel', 'technology', 'sports scores',
        'stock market', 'music playlist', 'fitness tips', 'book reviews'
    ];

    // 配置参数
    const config = {
        restTime: 5 * 60, // 无进度时休息时间（秒）
        scrollTime: 10, // 滚动时间（秒）
        waitTime: 10, // 获取进度后等待时间（秒）
        searchInterval: [5, 10], // 搜索间隔范围（秒）
        maxNoProgressCount: 3, // 连续多少次不增加分数才休息
        fallbackSearchCount: 20 // 无法从侧栏获取积分时的保底搜索次数
    };

    // 工作状态
    const searchState = {
        currentAction: 'idle', // 当前动作：idle, searching, scrolling, checking, waiting, resting
        countdown: 0, // 倒计时
        needRest: false, // 是否需要休息
        isCollapsed: true, // UI默认折叠
        fallbackMode: false // 无法从侧栏获取积分时按次数搜索
    };

    // 本地存储键名
    const STORAGE_KEY = 'bing_rewards_auto_searcher_state';
    const CONFIG_STORAGE_KEY = 'bing_rewards_config';

    // detect dark mode - prioritize Bing's own setting over system
    function isDarkMode() {
        const html = document.documentElement;
        // Bing uses b_dark class or data-darkmode attribute
        if (html.classList.contains('b_dark') || document.body.classList.contains('b_dark')) return true;
        if (html.getAttribute('data-darkmode') === 'true') return true;
        // if Bing page is loaded, trust its class (no b_dark = light mode)
        if (document.body) return false;
        // fallback to system setting only if page not ready
        return window.matchMedia('(prefers-color-scheme: dark)').matches;
    }

    // color theme
    function getTheme() {
        const dark = isDarkMode();
        return {
            bg: dark ? '#2d2d2d' : '#fff',
            border: dark ? '#444' : '#ddd',
            text: dark ? '#e0e0e0' : '#333',
            textSecondary: dark ? '#aaa' : '#666',
            inputBg: dark ? '#3a3a3a' : '#fff',
            inputBorder: dark ? '#555' : '#ccc',
            accent: '#0078d4',
            accentDanger: '#d83b01',
        };
    }

    // save config to localStorage
    function saveConfig() {
        try {
            localStorage.setItem(CONFIG_STORAGE_KEY, JSON.stringify({
                restTime: config.restTime,
                scrollTime: config.scrollTime,
                waitTime: config.waitTime,
                maxNoProgressCount: config.maxNoProgressCount,
                fallbackSearchCount: config.fallbackSearchCount
            }));
        } catch (e) { /* ignore */ }
    }

    // load config from localStorage
    function loadConfig() {
        try {
            const saved = localStorage.getItem(CONFIG_STORAGE_KEY);
            if (saved) {
                const c = JSON.parse(saved);
                if (c.restTime) config.restTime = c.restTime;
                if (c.scrollTime) config.scrollTime = c.scrollTime;
                if (c.waitTime) config.waitTime = c.waitTime;
                if (c.maxNoProgressCount) config.maxNoProgressCount = c.maxNoProgressCount;
                if (typeof c.fallbackSearchCount === 'number' && c.fallbackSearchCount > 0) {
                    config.fallbackSearchCount = c.fallbackSearchCount;
                }
            }
        } catch (e) { /* ignore */ }
    }

    // load saved config on startup
    loadConfig();

    // 保存状态到localStorage
    function saveState() {
        const state = {
            isSearching: isSearching,
            currentProgress: currentProgress,
            fallbackMode: searchState.fallbackMode,
            usedSearchTerms: usedSearchTerms,
            searchStartTime: Date.now(),
            lastActivityTime: Date.now(),
            mainPageSearchTerms: mainPageSearchTerms,
            iframeSearchTerms: iframeSearchTerms
        };
        try {
            localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
            console.log('状态已保存到本地存储');
        } catch (e) {
            console.log('保存状态失败:', e.message);
        }
    }

    // 从localStorage加载状态
    function loadState() {
        try {
            const savedState = localStorage.getItem(STORAGE_KEY);
            if (savedState) {
                const state = JSON.parse(savedState);
                const timeSinceLastActivity = Date.now() - (state.lastActivityTime || 0);
                const maxInactiveTime = 5 * 60 * 1000; // 5分钟

                // 如果超过5分钟未活动，清除状态
                if (timeSinceLastActivity > maxInactiveTime) {
                    console.log('状态已过期，清除本地存储');
                    clearState();
                    return null;
                }

                console.log('从本地存储加载状态:', state);
                return state;
            }
        } catch (e) {
            console.log('加载状态失败:', e.message);
        }
        return null;
    }

    // 清除localStorage中的状态
    function clearState() {
        try {
            localStorage.removeItem(STORAGE_KEY);
            console.log('已清除本地存储状态');
        } catch (e) {
            console.log('清除状态失败:', e.message);
        }
    }

    // 创建UI控件
    function createUI() {
        const theme = getTheme();

        const container = document.createElement('div');
        container.id = 'rewards-helper-container';
        container.style.cssText = `
            position: fixed;
            bottom: 20px;
            right: 20px;
            background-color: ${theme.bg};
            color: ${theme.text};
            border: 1px solid ${theme.border};
            border-radius: 6px;
            padding: 8px;
            z-index: 10000;
            box-shadow: 0 2px 8px rgba(0,0,0,0.3);
            width: 260px;
            font-size: 12px;
            line-height: 1.4;
        `;

        const header = document.createElement('div');
        header.style.cssText = `
            font-weight: bold;
            margin-bottom: 6px;
            border-bottom: 1px solid ${theme.border};
            padding-bottom: 4px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: move;
            font-size: 13px;
        `;

        const headerTitle = document.createElement('span');
        headerTitle.textContent = 'Microsoft Rewards 助手';
        header.appendChild(headerTitle);

        const controlsContainer = document.createElement('div');
        controlsContainer.style.display = 'flex';
        controlsContainer.style.alignItems = 'center';

        const qrCodeImageUrls = [
            'https://image.baidu.com/search/down?url=https://wx2.sinaimg.cn/mw690/006nCHZDgy1i2fa24fhc5j30u017jage.jpg',
            'https://image.baidu.com/search/down?url=https://wx1.sinaimg.cn/mw690/006nCHZDgy1i2fay7ltqdj30u017jn67.jpg',
            'https://image.baidu.com/search/down?url=https://wx1.sinaimg.cn/mw690/006nCHZDgy1i3g6ouikq1j30u018pthj.jpg'
        ];

        const qrCodeContainer = document.createElement('div');
        qrCodeContainer.style.cssText = `
            display: none;
            position: fixed;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            background-color: white;
            padding: 15px;
            border: 1px solid #ccc;
            border-radius: 5px;
            box-shadow: 0 0 10px rgba(0,0,0,0.2);
            z-index: 10002;
            flex-direction: row;
            gap: 15px;
        `;

        qrCodeImageUrls.forEach(url => {
            if (!url.startsWith('//')) { // 忽略被注释掉的链接
                const img = document.createElement('img');
                img.src = url;
                img.style.cssText = `
                    width: 234px; /* 180px增大30% */
                    height: auto;
                    display: block;
                `;
                qrCodeContainer.appendChild(img);
            }
        });

        const minimizeBtn = document.createElement('span');
        minimizeBtn.id = 'minimize-btn';
        minimizeBtn.textContent = '折叠';
        minimizeBtn.style.cssText = `
            cursor: pointer;
            font-size: 14px;
            margin-right: 8px;
        `;
        minimizeBtn.onclick = toggleCollapse;
        controlsContainer.appendChild(minimizeBtn);

        const closeBtn = document.createElement('span');
        closeBtn.textContent = '×';
        closeBtn.style.cssText = `
            cursor: pointer;
            font-size: 18px;
        `;
        closeBtn.onclick = function () {
            container.style.display = 'none';
        };
        controlsContainer.appendChild(closeBtn);
        header.appendChild(controlsContainer);

        const content = document.createElement('div');
        content.id = 'rewards-helper-content';
        content.style.cssText = `
            margin-bottom: 6px;
        `;

        const progress = document.createElement('div');
        progress.id = 'rewards-progress';
        progress.textContent = '进度: 加载中...';
        content.appendChild(progress);

        const searchStatus = document.createElement('div');
        searchStatus.id = 'search-status';
        searchStatus.style.cssText = `
            margin-top: 3px;
            font-style: italic;
            color: ${theme.textSecondary};
            font-size: 11px;
        `;
        content.appendChild(searchStatus);

        const countdown = document.createElement('div');
        countdown.id = 'countdown';
        countdown.style.cssText = `
            margin-top: 3px;
            font-weight: bold;
            color: ${theme.accent};
        `;
        content.appendChild(countdown);

        const searchTermsContainer = document.createElement('div');
        searchTermsContainer.id = 'rewards-search-terms-container';
        searchTermsContainer.style.cssText = `
            margin-top: 6px;
            max-height: 120px;
            overflow-y: auto;
            font-size: 11px;
        `;

        const mainTermsTitle = document.createElement('div');
        mainTermsTitle.textContent = '主页面搜索词:';
        mainTermsTitle.style.fontWeight = 'bold';
        searchTermsContainer.appendChild(mainTermsTitle);

        const mainTerms = document.createElement('div');
        mainTerms.id = 'main-search-terms';
        mainTerms.style.cssText = `
            margin-bottom: 6px;
            padding-left: 8px;
        `;
        searchTermsContainer.appendChild(mainTerms);

        const iframeTermsTitle = document.createElement('div');
        iframeTermsTitle.textContent = '侧栏中推荐的搜索词:';
        iframeTermsTitle.style.fontWeight = 'bold';
        searchTermsContainer.appendChild(iframeTermsTitle);

        const iframeTerms = document.createElement('div');
        iframeTerms.id = 'iframe-search-terms';
        iframeTerms.style.cssText = `
            padding-left: 8px;
        `;
        searchTermsContainer.appendChild(iframeTerms);

        content.appendChild(searchTermsContainer);

        // 每日点击任务显示区域
        const dailyTasksSection = document.createElement('div');
        dailyTasksSection.id = 'daily-tasks-section';
        dailyTasksSection.style.cssText = `
            margin-top: 6px;
        `;

        const dailyTasksTitle = document.createElement('div');
        dailyTasksTitle.id = 'daily-tasks-summary';
        dailyTasksTitle.textContent = '每日任务：加载中...';
        dailyTasksTitle.style.cssText = `
            font-weight: bold;
            margin-bottom: 2px;
        `;
        dailyTasksSection.appendChild(dailyTasksTitle);

        const dailyTasksList = document.createElement('div');
        dailyTasksList.id = 'daily-tasks-list';
        dailyTasksList.style.cssText = `
            padding-left: 8px;
            margin-bottom: 6px;
            font-size: 11px;
        `;
        dailyTasksSection.appendChild(dailyTasksList);

        content.appendChild(dailyTasksSection);

        const configSection = document.createElement('div');
        configSection.id = 'rewards-config-section';
        configSection.style.cssText = `
            margin-top: 6px;
            border-top: 1px solid ${theme.border};
            padding-top: 6px;
        `;

        const configTitle = document.createElement('div');
        configTitle.textContent = '配置参数:';
        configTitle.style.fontWeight = 'bold';
        configSection.appendChild(configTitle);

        const configForm = document.createElement('div');
        configForm.style.cssText = `
            display: grid;
            grid-template-columns: auto auto;
            gap: 3px;
            margin-top: 3px;
            font-size: 11px;
        `;

        // 添加休息时间配置（用DOM API替代innerHTML，避免TrustedHTML CSP错误）
        const configItems = [
            { label: '休息时间(分):', id: 'rest-time', value: config.restTime / 60, min: 1, max: 30 },
            { label: '滚动时间(秒):', id: 'scroll-time', value: config.scrollTime, min: 3, max: 30 },
            { label: '等待时间(秒):', id: 'wait-time', value: config.waitTime, min: 3, max: 30 },
            { label: '容错次数:', id: 'max-no-progress', value: config.maxNoProgressCount, min: 1, max: 10 },
            { label: '保底次数:', id: 'fallback-count', value: config.fallbackSearchCount, min: 1, max: 90 }
        ];
        configItems.forEach(item => {
            const label = document.createElement('label');
            label.setAttribute('for', item.id);
            label.textContent = item.label;
            configForm.appendChild(label);

            const input = document.createElement('input');
            input.type = 'number';
            input.id = item.id;
            input.value = item.value;
            input.min = item.min;
            input.max = item.max;
            input.style.cssText = `width: 50px; background: ${theme.inputBg}; color: ${theme.text}; border: 1px solid ${theme.inputBorder}; border-radius: 3px; padding: 1px 3px;`;
            configForm.appendChild(input);
        });

        configSection.appendChild(configForm);

        // 添加输入框变化事件监听
        setTimeout(() => {
            const restTimeInput = document.getElementById('rest-time');
            const scrollTimeInput = document.getElementById('scroll-time');
            const waitTimeInput = document.getElementById('wait-time');
            const maxNoProgressInput = document.getElementById('max-no-progress');
            const fallbackCountInput = document.getElementById('fallback-count');

            if (restTimeInput) {
                restTimeInput.addEventListener('change', () => {
                    const restTime = parseInt(restTimeInput.value) || 5;
                    config.restTime = restTime * 60;
                    saveConfig();
                    updateStatus('休息时间已更新: ' + restTime + '分钟');
                });
            }

            if (scrollTimeInput) {
                scrollTimeInput.addEventListener('change', () => {
                    const scrollTime = parseInt(scrollTimeInput.value) || 10;
                    config.scrollTime = scrollTime;
                    saveConfig();
                    updateStatus('滚动时间已更新: ' + scrollTime + '秒');
                });
            }

            if (waitTimeInput) {
                waitTimeInput.addEventListener('change', () => {
                    const waitTime = parseInt(waitTimeInput.value) || 10;
                    config.waitTime = waitTime;
                    saveConfig();
                    updateStatus('等待时间已更新: ' + waitTime + '秒');
                });
            }

            if (maxNoProgressInput) {
                maxNoProgressInput.addEventListener('change', () => {
                    const maxNoProgressCount = parseInt(maxNoProgressInput.value) || 3;
                    config.maxNoProgressCount = maxNoProgressCount;
                    saveConfig();
                    updateStatus('容错次数已更新: ' + maxNoProgressCount + '次');
                });
            }

            if (fallbackCountInput) {
                fallbackCountInput.addEventListener('change', () => {
                    const fallbackCount = parseInt(fallbackCountInput.value) || 20;
                    config.fallbackSearchCount = Math.max(1, fallbackCount);
                    saveConfig();
                    updateStatus('保底搜索次数已更新: ' + config.fallbackSearchCount + '次');
                    if (searchState.fallbackMode) {
                        currentProgress.total = config.fallbackSearchCount;
                        updateProgressDisplay();
                    }
                });
            }
        }, 1000);

        content.appendChild(configSection);

        const buttonsContainer = document.createElement('div');
        buttonsContainer.id = 'rewards-buttons-container';
        buttonsContainer.style.cssText = `
            display: flex;
            flex-direction: column;
            align-items: center;
            margin-top: 6px;
        `;

        const startSearchBtn = document.createElement('button');
        startSearchBtn.id = 'start-search-btn';
        startSearchBtn.textContent = '开始自动搜索';
        startSearchBtn.style.cssText = `
            padding: 4px 8px;
            cursor: pointer;
            background-color: ${theme.accent};
            color: white;
            border: none;
            border-radius: 3px;
            width: 100%;
            font-size: 12px;
        `;
        startSearchBtn.onclick = function () {
            if (!isSearching) {
                startAutomatedSearch();
            } else {
                stopAutomatedSearch();
            }
        };
        buttonsContainer.appendChild(startSearchBtn);

        // 底部链接容器
        const linksContainer = document.createElement('div');
        linksContainer.style.cssText = `
            display: flex;
            justify-content: center;
            gap: 15px;
            margin-top: 8px;
            width: 100%;
        `;

        // 支持作者链接移到这里（之前的adTrigger）
        const supportAuthorContainer = document.createElement('div');
        supportAuthorContainer.style.cssText = 'position: relative;';

        const supportAuthorLink = document.createElement('span');
        supportAuthorLink.textContent = '🧧 支持作者';
        supportAuthorLink.style.cssText = 'cursor: pointer; font-size: 12px; color: #f44336; font-weight: bold;';

        supportAuthorLink.addEventListener('click', (e) => {
            e.preventDefault();
            qrCodeContainer.style.display = 'flex';

            // 创建遮罩层
            const overlay = document.createElement('div');
            overlay.style.cssText = `
                position: fixed;
                top: 0;
                left: 0;
                width: 100%;
                height: 100%;
                background-color: rgba(0, 0, 0, 0.5);
                z-index: 10001;
            `;

            // 点击遮罩层关闭弹窗
            overlay.addEventListener('click', () => {
                document.body.removeChild(overlay);
                qrCodeContainer.style.display = 'none';
            });

            document.body.appendChild(overlay);

            // 将弹窗添加到body
            if (qrCodeContainer.parentElement !== document.body) {
                document.body.appendChild(qrCodeContainer);
            }
        });

        supportAuthorContainer.appendChild(supportAuthorLink);
        supportAuthorContainer.appendChild(qrCodeContainer);
        linksContainer.appendChild(supportAuthorContainer);

        // 给个好评链接
        const rateLink = document.createElement('a');
        rateLink.href = 'https://greasyfork.org/zh-CN/scripts/538825/feedback#post-discussion';
        rateLink.target = '_blank';
        rateLink.textContent = '👍 给个好评';
        rateLink.style.cssText = 'font-size: 12px; color: #4CAF50; font-weight: bold; text-decoration: none;';
        linksContainer.appendChild(rateLink);

        buttonsContainer.appendChild(linksContainer);

        container.appendChild(header);
        container.appendChild(content);
        container.appendChild(buttonsContainer);
        document.body.appendChild(container);
        makeDraggable(container, header);
    }

    // 让UI窗口可拖动
    function makeDraggable(container, header) {
        let offsetX, offsetY;
        let isDragging = false;

        const onMouseDown = (e) => {
            // 如果点击的是按钮（它们有自己的pointer光标），则不触发拖动
            if (window.getComputedStyle(e.target).cursor === 'pointer') {
                return;
            }

            isDragging = true;

            // switch from bottom/right positioning to top/left for dragging
            if (container.style.bottom || container.style.right) {
                const rect = container.getBoundingClientRect();
                container.style.left = rect.left + 'px';
                container.style.top = rect.top + 'px';
                container.style.right = '';
                container.style.bottom = '';
            }

            offsetX = e.clientX - container.offsetLeft;
            offsetY = e.clientY - container.offsetTop;

            document.body.style.userSelect = 'none';
            document.addEventListener('mousemove', onMouseMove);
            document.addEventListener('mouseup', onMouseUp, { once: true }); // Use {once: true} for cleanup
        };

        const onMouseMove = (e) => {
            if (!isDragging) return;

            container.style.top = (e.clientY - offsetY) + 'px';
            container.style.left = (e.clientX - offsetX) + 'px';
        };

        const onMouseUp = () => {
            isDragging = false;
            document.body.style.userSelect = '';
            document.removeEventListener('mousemove', onMouseMove);
        };

        header.addEventListener('mousedown', onMouseDown);
    }

    function updateProgressDisplay(extra = '') {
        const progressElement = document.getElementById('rewards-progress');
        if (!progressElement) return;

        if (!currentProgress.total) {
            progressElement.textContent = extra ? extra : '进度: 加载中...';
            return;
        }

        const suffix = extra || (currentProgress.completed ? ' (已完成)' : (searchState.fallbackMode ? ' (按次数)' : ''));
        progressElement.textContent = `进度: ${currentProgress.current}/${currentProgress.total}${suffix}`;
    }

    // 无法从侧栏获取积分时，按手动指定次数搜索
    function enableFallbackSearchMode(reason) {
        if (!searchState.fallbackMode) {
            searchState.fallbackMode = true;
            currentProgress.current = 0;
            currentProgress.lastChecked = 0;
            currentProgress.noProgressCount = 0;
            currentProgress.completed = false;
        }
        currentProgress.total = config.fallbackSearchCount;
        updateProgressDisplay();
        updateStatus(reason || `无法从侧栏获取积分，将按 ${config.fallbackSearchCount} 次搜索`);
        updateAndSaveState();
    }

    // 更新状态显示
    function updateStatus(message) {
        const statusElement = document.getElementById('search-status');
        if (statusElement) {
            statusElement.textContent = message;
            // 确保在折叠状态下也显示状态
            if (searchState.isCollapsed) {
                statusElement.style.display = 'block';
            }
        }
        console.log(message);
    }

    // 切换UI折叠状态
    function toggleCollapse() {
        searchState.isCollapsed = !searchState.isCollapsed;
        applyCollapseState();
    }

    // 应用折叠状态
    function applyCollapseState() {
        const searchTermsContainer = document.getElementById('rewards-search-terms-container');
        const configSection = document.getElementById('rewards-config-section');
        const dailyTasksSection = document.getElementById('daily-tasks-section');
        const tasksList = document.getElementById('daily-tasks-list');
        const content = document.getElementById('rewards-helper-content');
        const minimizeBtn = document.getElementById('minimize-btn');
        const statusElem = document.getElementById('search-status');

        if (searchState.isCollapsed) {
            // 折叠
            if (searchTermsContainer) searchTermsContainer.style.display = 'none';
            if (configSection) configSection.style.display = 'none';
            if (tasksList) tasksList.style.display = 'none';
            // 保留进度和状态信息
            if (content) {
                const progressElem = document.getElementById('rewards-progress');
                const countdownElem = document.getElementById('countdown');

                if (progressElem) progressElem.style.marginBottom = '0';
                // 状态元素保持显示
                if (statusElem) {
                    statusElem.style.marginTop = '3px';
                    statusElem.style.marginBottom = '0';
                }
                if (countdownElem && countdownElem.style.display !== 'none') {
                    countdownElem.style.marginBottom = '0';
                    countdownElem.style.marginTop = '3px';
                }
            }
            if (minimizeBtn) minimizeBtn.textContent = '展开';
        } else {
            // 展开
            if (searchTermsContainer) searchTermsContainer.style.display = 'block';
            if (configSection) configSection.style.display = 'block';
            if (tasksList) tasksList.style.display = 'block';
            // 恢复所有内容显示
            if (content) {
                const progressElem = document.getElementById('rewards-progress');
                const countdownElem = document.getElementById('countdown');

                if (progressElem) progressElem.style.marginBottom = '';
                if (statusElem) {
                    statusElem.style.marginTop = '5px';
                    statusElem.style.marginBottom = '';
                }
                if (countdownElem) {
                    countdownElem.style.marginBottom = '';
                    countdownElem.style.marginTop = '5px';
                }
            }
            if (minimizeBtn) minimizeBtn.textContent = '折叠';
        }
    }

    // 更新倒计时显示
    function updateCountdown(seconds, action) {
        const countdownElement = document.getElementById('countdown');
        if (countdownElement) {
            if (seconds > 0) {
                let actionText = '';
                switch (action) {
                    case 'scrolling': actionText = '滚动中'; break;
                    case 'waiting': actionText = '等待中'; break;
                    case 'resting': actionText = '休息中'; break;
                    case 'checking': actionText = '检查中'; break;
                    default: actionText = '倒计时';
                }
                countdownElement.textContent = `${actionText}: ${seconds}秒`;
                countdownElement.style.display = 'block';
            } else {
                countdownElement.style.display = 'none';
            }
        }
    }

    // 更新每日点击任务 UI
    function updateDailyTasksUI(tasks) {
        const tasksList = document.getElementById('daily-tasks-list');
        if (!tasksList) return;

        const summaryElem = document.getElementById('daily-tasks-summary');

        while (tasksList.firstChild) tasksList.removeChild(tasksList.firstChild);

        // 生成 summary 图标
        let summaryIcons = '';
        if (!tasks || tasks.length === 0) {
            summaryIcons = '✅✅✅';
        } else {
            summaryIcons = tasks
                .map(t => (t.status === '已完成' ? '✅' : t.status === '未完成' ? '❌' : '❔'))
                .join('');
        }

        if (summaryElem) {
            summaryElem.textContent = `每日任务：${summaryIcons}`;
        }

        // 详细列表
        if (!tasks || tasks.length === 0) {
            const doneElem = document.createElement('div');
            doneElem.textContent = '每日任务已全部完成';
            doneElem.style.color = '#4CAF50';
            tasksList.appendChild(doneElem);
            return;
        }

        tasks.forEach(task => {
            const taskElem = document.createElement('div');
            taskElem.textContent = `${task.name}: ${task.status}`;
            taskElem.style.color = task.status === '未完成' ? '#d83b01' : '#4CAF50';
            tasksList.appendChild(taskElem);
        });
    }

    // 点击打开侧边栏
    function openRewardsSidebar() {
        const pointsContainer = document.querySelector('.points-container');
        if (pointsContainer) {
            pointsContainer.click();
            console.log('已点击积分按钮，正在打开侧边栏...');
            return true;
        } else {
            console.log('未找到积分按钮');
            return false;
        }
    }

    // 从iframe中获取数据
    function getDataFromIframe() {
        const iframe = document.querySelector('iframe');
        if (!iframe) {
            console.log('未找到iframe');
            return false;
        }

        try {
            const iframeDoc = iframe.contentDocument || iframe.contentWindow.document;
            console.log('成功访问iframe文档');

            // 解析每日点击任务
            (() => {
                const tasks = [];

                const offersContainer = iframeDoc.querySelector('#bingRewards .flyout_control_threeOffers');
                if (!offersContainer) {
                    console.log('[RewardsHelper] 未找到每日三连任务容器 .flyout_control_threeOffers，视为全部完成');
                    updateDailyTasksUI([]);
                    dailyTasksData = [];
                } else {
                    const offerDivs = offersContainer.querySelectorAll('div[aria-label*="Offer"]');
                    console.log('[RewardsHelper] 在每日任务容器中找到 offer 元素数量:', offerDivs.length);

                    offerDivs.forEach((div, idx) => {
                        if (tasks.length >= 3) return; // 最多三个

                        const ariaLabel = div.getAttribute('aria-label') || '';
                        console.log(`[RewardsHelper] DailyOffer(${idx}) aria-label:`, ariaLabel);

                        let status = '未知';
                        const lowerLabel = ariaLabel.toLowerCase();
                        if (lowerLabel.includes('offer not completed')) {
                            status = '未完成';
                        } else if (lowerLabel.includes('offer is completed') || lowerLabel.includes('offer completed')) {
                            status = '已完成';
                        }

                        const name = ariaLabel.split(' - ')[0] || `任务${idx + 1}`;
                        tasks.push({ name, status });
                    });

                    console.log('[RewardsHelper] 解析的每日任务:', tasks);

                    updateDailyTasksUI(tasks);
                    dailyTasksData = tasks;
                }

            })();

            // 获取进度 - 优先检查实际进度，再检查完成提示
            // 1. 首先尝试获取正常进度显示
            let progressFound = false;
            const progressElement = iframeDoc.querySelector('.daily_search_row span:last-child');
            if (progressElement) {
                const progress = progressElement.textContent;
                console.log('搜索进度: ' + progress);

                // 解析进度数字
                const match = progress.match(/(\d+)\/(\d+)/);
                if (match) {
                    const current = parseInt(match[1]);
                    currentProgress.total = parseInt(match[2]);
                    searchState.fallbackMode = false;

                    // 检查进度是否增加
                    if (currentProgress.lastChecked > 0 && current <= currentProgress.lastChecked && isSearching) {
                        console.log(`进度未增加: ${current} <= ${currentProgress.lastChecked}，已连续 ${currentProgress.noProgressCount + 1} 次未增加`);
                        currentProgress.noProgressCount++;

                        // 只有当连续多次未增加进度时才休息
                        if (currentProgress.noProgressCount >= config.maxNoProgressCount) {
                            searchState.needRest = true;
                            console.log(`达到最大容错次数 ${config.maxNoProgressCount}，需要休息`);
                        }
                    } else if (current > currentProgress.lastChecked) {
                        // 进度增加，重置计数器
                        console.log(`进度增加: ${current} > ${currentProgress.lastChecked}，重置未增加计数`);
                        currentProgress.noProgressCount = 0;
                    }

                    currentProgress.current = current;
                    currentProgress.lastChecked = current;

                    // 检查是否完成
                    if (current >= currentProgress.total) {
                        currentProgress.completed = true;
                        console.log(`进度数字表明任务已完成: ${current}/${currentProgress.total}`);
                    }

                    updateProgressDisplay();
                    updateAndSaveState();
                    progressFound = true;

                    // 不再提前返回，继续往下获取搜索词
                }
            } else {
                console.log('未找到进度元素，检查完成提示');
            }

            // 2. 只有在没有找到进度元素时，才检查完成提示和假提示
            if (!progressFound) {
            const allElements = iframeDoc.querySelectorAll('*');
            
            // 先收集所有包含关键词的文本（限制长度，避免收集过多内容）
            let earnedTexts = [];
            for (let element of allElements) {
                const text = element.textContent || '';
                // 只处理相对较短的文本，避免收集整个页面内容
                if (text.length < 500) {
                    if (text.includes('你已获得') && text.includes('积分')) {
                        earnedTexts.push(text);
                    }
                    if (text.includes('You earned') && text.includes('points')) {
                        earnedTexts.push(text);
                    }
                }
            }
            
            // 将所有相关文本合并，用于综合判断
            const allEarnedText = earnedTexts.join(' ');
            console.log('收集到的相关文本:', earnedTexts);
            console.log('合并后的文本:', allEarnedText);
            
            // 检查中文假提示
            if (allEarnedText.includes('你已获得') && allEarnedText.includes('积分') && allEarnedText.includes('每天继续搜索')) {
                console.log(`检测到中文假提示`);
                
                const currentMatch = allEarnedText.match(/你已获得\s*(\d+)\s*积分/);
                const totalMatch = allEarnedText.match(/每天继续搜索并获得最多\s*(\d+)\s*奖励积分/);
                
                if (currentMatch && totalMatch) {
                    const currentPoints = parseInt(currentMatch[1]);
                    const totalPoints = parseInt(totalMatch[1]);
                    
                    console.log(`从中文假提示中提取: 当前${currentPoints}分，总共${totalPoints}分`);
                    
                    currentProgress.current = currentPoints;
                    currentProgress.total = totalPoints;
                    currentProgress.lastChecked = currentPoints;
                    currentProgress.completed = false;
                    searchState.fallbackMode = false;

                    updateProgressDisplay(' (从提示获取)');
                    console.log(`从中文假提示更新进度: ${currentPoints}/${totalPoints}`);
                    
                    updateAndSaveState();
                    return true;
                }
            }
            
            // 检查英文假提示
            if (allEarnedText.includes('You earned') && allEarnedText.includes('points') && allEarnedText.includes('Keep searching')) {
                console.log(`检测到英文假提示`);
                
                // 修复正则表达式，处理可能的变体
                const currentMatch = allEarnedText.match(/You earned\s*(\d+)\s*points?(?:\s+already)?/i);
                const totalMatch = allEarnedText.match(/(?:earn\s+up\s+to|get\s+up\s+to)\s*(\d+)\s*(?:Rewards\s+)?points?/i);
                
                console.log('当前积分匹配:', currentMatch);
                console.log('总积分匹配:', totalMatch);
                
                if (currentMatch && totalMatch) {
                    const currentPoints = parseInt(currentMatch[1]);
                    const totalPoints = parseInt(totalMatch[1]);
                    
                    console.log(`从英文假提示中提取: 当前${currentPoints}分，总共${totalPoints}分`);
                    
                    currentProgress.current = currentPoints;
                    currentProgress.total = totalPoints;
                    currentProgress.lastChecked = currentPoints;
                    currentProgress.completed = false;
                    searchState.fallbackMode = false;

                    updateProgressDisplay(' (从提示获取)');
                    console.log(`从英文假提示更新进度: ${currentPoints}/${totalPoints}`);
                    
                    updateAndSaveState();
                    return true;
                } else {
                    console.log('英文假提示正则匹配失败');
                }
            }
            
            // 检查中文真正完成提示
            if (allEarnedText.includes('你已获得') && allEarnedText.includes('积分') && !allEarnedText.includes('每天继续搜索')) {
                console.log(`找到中文完成文本`);
                const match = allEarnedText.match(/你已获得\s*(\d+)\s*积分/);
                if (match) {
                    const totalPoints = parseInt(match[1]);
                    currentProgress.current = totalPoints;
                    currentProgress.total = totalPoints;
                    currentProgress.completed = true;
                    searchState.fallbackMode = false;

                    updateProgressDisplay(' (已完成)');
                    console.log(`搜索任务已完成! 总积分: ${totalPoints}`);

                    clearState();
                    return true;
                }
            }

            // 检查英文真正完成提示
            if (allEarnedText.includes('You earned') && allEarnedText.includes('points already') && !allEarnedText.includes('Keep searching')) {
                console.log(`找到英文完成文本`);
                const match = allEarnedText.match(/You earned\s*(\d+)\s*points already/i);
                if (match) {
                    const totalPoints = parseInt(match[1]);
                    currentProgress.current = totalPoints;
                    currentProgress.total = totalPoints;
                    currentProgress.completed = true;
                    searchState.fallbackMode = false;

                    updateProgressDisplay(' (已完成)');
                    console.log(`搜索任务已完成! 总积分: ${totalPoints}`);
                    
                    clearState();
                    return true;
                }
            }
            } // end if (!progressFound)

            // 获取iframe中的搜索词
            let iframeTermsFound = false;

            // method 1: from window.flyoutViewModel variable in iframe
            try {
                const iframeWin = iframe.contentWindow;
                if (iframeWin && iframeWin.flyoutViewModel) {
                    const vm = iframeWin.flyoutViewModel;
                    // try both paths: flyoutResult.suggestedSearches and suggestedSearches
                    const ss = (vm.flyoutResult && vm.flyoutResult.suggestedSearches) || vm.suggestedSearches;
                    if (ss && ss.suggestedItems) {
                        const terms = ss.suggestedItems.map(item => item.query).filter(q => q);
                        if (terms.length > 0) {
                            iframeSearchTerms = [...terms];
                            iframeTermsFound = true;
                            console.log('从flyoutViewModel变量找到iframe搜索词: ' + terms.length + '个');
                        }
                    }
                }
            } catch (e2) {
                console.log('从flyoutViewModel变量获取失败:', e2.message);
            }

            // method 2: parse flyoutViewModel JSON from script tags in iframe
            if (!iframeTermsFound) {
                try {
                    const scripts = iframeDoc.querySelectorAll('script');
                    for (const script of scripts) {
                        const text = script.textContent || '';
                        const idx = text.indexOf('window.flyoutViewModel');
                        if (idx === -1) continue;
                        // find the opening brace
                        const braceStart = text.indexOf('{', idx);
                        if (braceStart === -1) continue;
                        // count braces to find the matching closing brace
                        let depth = 0;
                        let braceEnd = -1;
                        for (let k = braceStart; k < text.length; k++) {
                            if (text[k] === '{') depth++;
                            else if (text[k] === '}') { depth--; if (depth === 0) { braceEnd = k; break; } }
                        }
                        if (braceEnd === -1) continue;
                        try {
                            const viewModel = JSON.parse(text.substring(braceStart, braceEnd + 1));
                            const ss = (viewModel.flyoutResult && viewModel.flyoutResult.suggestedSearches) || viewModel.suggestedSearches;
                            if (ss && ss.suggestedItems) {
                                const terms = ss.suggestedItems
                                    .map(item => item.query).filter(q => q);
                                if (terms.length > 0) {
                                    iframeSearchTerms = [...terms];
                                    iframeTermsFound = true;
                                    console.log('从script标签解析找到iframe搜索词: ' + terms.length + '个');
                                }
                            }
                        } catch (parseErr) {
                            console.log('JSON解析失败:', parseErr.message);
                        }
                        break;
                    }
                } catch (e3) {
                    console.log('从script标签解析搜索词失败:', e3.message);
                }
            }

            // method 3: fallback to old DOM selector
            if (!iframeTermsFound) {
                const searchTermsContainer = iframeDoc.querySelector('.ss_items_wrapper');
                if (searchTermsContainer) {
                    const terms = [];
                    const spans = searchTermsContainer.querySelectorAll('span');
                    spans.forEach(span => {
                        terms.push(span.textContent);
                    });
                    if (terms.length > 0) {
                        iframeSearchTerms = [...terms];
                        iframeTermsFound = true;
                        console.log('从DOM找到iframe搜索词: ' + terms.length + '个');
                    }
                }
            }

            // update sidebar terms UI
            if (iframeTermsFound) {
                const termsContainer = document.getElementById('iframe-search-terms');
                if (termsContainer) {
                    while (termsContainer.firstChild) termsContainer.removeChild(termsContainer.firstChild);
                    iframeSearchTerms.forEach(term => {
                        const termElem = document.createElement('div');
                        termElem.textContent = term;
                        termsContainer.appendChild(termElem);
                    });
                }
            } else {
                console.log('所有方法均未找到iframe搜索词');
            }

            return true;
        } catch (e) {
            console.log('读取iframe内容出错: ' + e.message);
            return false;
        }
    }

    // 从主文档中获取搜索词
    function getSearchTermsFromMainDoc() {
        const terms = [];
        const currentQ = new URLSearchParams(window.location.search).get('q') || '';

        // method 1: new format - "深入了解" section with b_vList b_divsec
        document.querySelectorAll('.b_vList.b_divsec a[href*="/search?q="]').forEach(a => {
            const text = a.textContent.trim();
            if (text.length > 2 && text.length < 60 && text !== currentQ) {
                terms.push(text);
            }
        });

        // method 2: rslist links
        if (terms.length === 0) {
            document.querySelectorAll('.rslist a[href*="/search?q="]').forEach(a => {
                const text = a.textContent.trim();
                if (text.length > 2 && text.length < 60 && text !== currentQ) {
                    terms.push(text);
                }
            });
        }

        // method 3: old format - richrsrailsugwrapper
        if (terms.length === 0) {
            const suggestionsContainer = document.querySelector('.richrsrailsugwrapper');
            if (suggestionsContainer) {
                suggestionsContainer.querySelectorAll('.richrsrailsuggestion_text').forEach(el => {
                    terms.push(el.textContent.trim());
                });
            }
        }

        if (terms.length > 0) {
            // deduplicate
            mainPageSearchTerms = [...new Set(terms)];

            const termsContainer = document.getElementById('main-search-terms');
            if (termsContainer) {
                termsContainer.textContent = '';
                mainPageSearchTerms.forEach(term => {
                    const termElem = document.createElement('div');
                    termElem.textContent = term;
                    termsContainer.appendChild(termElem);
                });
            }
            console.log('找到主页面搜索词: ' + mainPageSearchTerms.length + '个');
            return true;
        } else {
            console.log('未找到主页面搜索词');
            return false;
        }
    }

    // 如果没有任何搜索词，使用保底搜索词
    function ensureFallbackSearchTerms() {
        if (mainPageSearchTerms.length === 0 && iframeSearchTerms.length === 0) {
            mainPageSearchTerms = [...fallbackSearchTerms];

            // 更新 UI
            const termsContainer = document.getElementById('main-search-terms');
            if (termsContainer) {
                termsContainer.textContent = '';
                mainPageSearchTerms.forEach(term => {
                    const termElem = document.createElement('div');
                    termElem.textContent = term;
                    termsContainer.appendChild(termElem);
                });
            }

            console.log('[RewardsHelper] 使用保底搜索词:', fallbackSearchTerms);
            updateStatus('使用保底搜索词启动');
            return true;
        }
        return false;
    }

    // 获取Rewards数据（带重试机制）
    function getRewardsData(callback, retryCount = 0, maxRetries = 3) {
        updateStatus('正在获取奖励数据...');
        
        if (openRewardsSidebar()) {
            // 使用轮询检查iframe是否加载完成
            let attempts = 0;
            const maxAttempts = 20; // 最多尝试20次，每次500ms，总共10秒
            
            const checkIframeReady = () => {
                attempts++;
                
                try {
                    const iframe = document.querySelector('iframe');
                    if (!iframe) {
                        if (attempts < maxAttempts) {
                            setTimeout(checkIframeReady, 500);
                            return;
                        } else {
                            throw new Error('未找到iframe');
                        }
                    }
                    
                    const iframeDoc = iframe.contentDocument || iframe.contentWindow.document;
                    if (!iframeDoc || iframeDoc.readyState !== 'complete') {
                        if (attempts < maxAttempts) {
                            setTimeout(checkIframeReady, 500);
                            return;
                        } else {
                            throw new Error('iframe未完全加载');
                        }
                    }
                    
                    // iframe已就绪，获取数据
                    const iframeLoaded = getDataFromIframe();
                    const mainTermsLoaded = getSearchTermsFromMainDoc();

                    if (!iframeLoaded && !mainTermsLoaded) {
                        throw new Error('获取数据失败');
                    }

                    if (!currentProgress.total && !currentProgress.completed) {
                        enableFallbackSearchMode('无法从侧栏获取积分，将按 ' + config.fallbackSearchCount + ' 次搜索');
                    } else {
                        updateStatus('数据获取成功');
                    }
                    updateAndSaveState(); // 保存状态

                    if (currentProgress.completed) {
                        updateStatus('搜索任务已完成！');
                        if (isSearching) {
                            showCompletionNotification();
                            stopAutomatedSearch();
                        }
                    }

                    // 如果检测到需要休息，并且正在搜索
                    if (searchState.needRest && isSearching && !searchState.fallbackMode) {
                        startResting();
                    } else if (callback) {
                        callback();
                    }
                    
                } catch (error) {
                    console.log(`数据获取尝试 ${attempts} 失败:`, error.message);
                    
                    if (attempts >= maxAttempts) {
                        // 达到最大尝试次数，考虑重试
                        if (retryCount < maxRetries) {
                            console.log(`第 ${retryCount + 1} 次重试获取数据...`);
                            updateStatus(`获取数据失败，正在重试 (${retryCount + 1}/${maxRetries})...`);
                            setTimeout(() => {
                                getRewardsData(callback, retryCount + 1, maxRetries);
                            }, 2000);
                        } else {
                            enableFallbackSearchMode('无法从侧栏获取积分，将按 ' + config.fallbackSearchCount + ' 次搜索');
                            if (callback) callback();
                        }
                    } else {
                        setTimeout(checkIframeReady, 500);
                    }
                }
            };
            
            // 开始检查iframe状态
            setTimeout(checkIframeReady, 500);
            
        } else {
            if (retryCount < maxRetries) {
                console.log(`未找到积分按钮，重试中... (${retryCount + 1}/${maxRetries})`);
                updateStatus(`未找到积分按钮，正在重试 (${retryCount + 1}/${maxRetries})...`);
                setTimeout(() => {
                    getRewardsData(callback, retryCount + 1, maxRetries);
                }, 2000);
            } else {
                enableFallbackSearchMode('未找到积分按钮，无法从侧栏获取积分，将按 ' + config.fallbackSearchCount + ' 次搜索');
                if (callback) callback();
            }
        }
    }

    // 开始休息
    function startResting() {
        searchState.needRest = false;
        // 重置未增加计数
        currentProgress.noProgressCount = 0;
        updateStatus(`连续 ${config.maxNoProgressCount} 次搜索无进度，休息 ${config.restTime / 60} 分钟后继续`);
        startCountdown(config.restTime, 'resting', () => {
            updateStatus('休息结束，继续搜索');
            setTimeout(performNextSearch, 1000);
        });
    }

    // generate random suffix to make search terms unique
    function generateRandomSuffix() {
        const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
        const len = Math.floor(Math.random() * 3) + 2; // 2-4 chars
        let suffix = '';
        for (let i = 0; i < len; i++) {
            suffix += chars.charAt(Math.floor(Math.random() * chars.length));
        }
        return suffix;
    }

    // check if current terms are from fallback list
    function isFallbackMode() {
        return mainPageSearchTerms.length > 0 &&
            mainPageSearchTerms.every(t => fallbackSearchTerms.includes(t)) &&
            iframeSearchTerms.length === 0;
    }

    // 获取搜索词（优先主页面，其次iframe）
    function getSearchTerm() {
        // 创建可用搜索词数组（排除已使用的搜索词）
        let availableMainTerms = mainPageSearchTerms.filter(term => !usedSearchTerms.includes(term));
        let availableIframeTerms = iframeSearchTerms.filter(term => !usedSearchTerms.includes(term));

        // 如果所有搜索词都已使用过，重置已使用列表
        if (availableMainTerms.length === 0 && availableIframeTerms.length === 0 &&
            (mainPageSearchTerms.length > 0 || iframeSearchTerms.length > 0)) {
            console.log('所有搜索词已用完，重置已使用列表');
            usedSearchTerms = [];
            availableMainTerms = [...mainPageSearchTerms];
            availableIframeTerms = [...iframeSearchTerms];
        }

        // 优先使用主页面搜索词
        if (availableMainTerms.length > 0) {
            const randomIndex = Math.floor(Math.random() * availableMainTerms.length);
            const baseTerm = availableMainTerms[randomIndex];
            // add random suffix in fallback mode to avoid duplicate searches
            const term = isFallbackMode() ? `${baseTerm} ${generateRandomSuffix()}` : baseTerm;
            // 添加到已使用列表
            usedSearchTerms.push(baseTerm);
            console.log(`选择搜索词: ${term} (主页面，还有 ${availableMainTerms.length - 1} 个未使用)`);
            return {
                term: term,
                source: isFallbackMode() ? '保底' : '主页面'
            };
        }
        // 如果主页面没有搜索词，使用iframe搜索词
        else if (availableIframeTerms.length > 0) {
            const randomIndex = Math.floor(Math.random() * availableIframeTerms.length);
            const term = availableIframeTerms[randomIndex];
            // 添加到已使用列表
            usedSearchTerms.push(term);
            console.log(`选择搜索词: ${term} (iframe，还有 ${availableIframeTerms.length - 1} 个未使用)`);
            return {
                term: term,
                source: 'iframe'
            };
        }

        // 如果都没有搜索词，返回null
        return null;
    }

    // 执行搜索
    function performSearch(term) {
        if (!term) return false;

        const searchBox = document.querySelector('#sb_form_q');
        if (searchBox) {
            // 填入搜索词
            searchBox.value = term;

            // 提交搜索
            const searchForm = document.querySelector('#sb_form');
            if (searchForm) {
                searchForm.submit();
                return true;
            }
        }
        return false;
    }

    // 模拟滚动
    function simulateScrolling(callback) {
        updateStatus('正在滚动页面...');
        searchState.currentAction = 'scrolling';

        // 开始倒计时
        startCountdown(config.scrollTime, 'scrolling', callback);

        // 模拟随机滚动
        const scrollInterval = setInterval(() => {
            // 随机滚动距离
            const scrollAmount = Math.floor(Math.random() * 300) + 100;
            const scrollDirection = Math.random() > 0.3 ? 1 : -1; // 70%向下，30%向上

            window.scrollBy(0, scrollAmount * scrollDirection);

            // 如果当前动作不是滚动，停止滚动
            if (searchState.currentAction !== 'scrolling') {
                clearInterval(scrollInterval);
            }
        }, 1000);

        // 滚动结束后停止滚动
        setTimeout(() => {
            clearInterval(scrollInterval);
        }, config.scrollTime * 1000);
    }

    // 按次数模式：每次搜索后手动累加进度
    function advanceFallbackProgress() {
        if (!searchState.fallbackMode) {
            enableFallbackSearchMode('无法从侧栏获取积分，将按 ' + config.fallbackSearchCount + ' 次搜索');
        }
        currentProgress.current += 1;
        currentProgress.lastChecked = currentProgress.current;
        if (currentProgress.current >= currentProgress.total) {
            currentProgress.completed = true;
        }
        updateProgressDisplay();
        updateAndSaveState();
    }

    // 检查进度
    function checkProgress(callback) {
        updateStatus('正在检查搜索进度...');
        searchState.currentAction = 'checking';

        if (openRewardsSidebar()) {
            setTimeout(() => {
                getDataFromIframe();
                // 同时从主页面获取搜索词
                getSearchTermsFromMainDoc();

                if (!currentProgress.total && !currentProgress.completed) {
                    enableFallbackSearchMode('无法从侧栏获取积分，将按 ' + config.fallbackSearchCount + ' 次搜索');
                }

                if (currentProgress.completed) {
                    showCompletionNotification();
                    updateStatus('搜索任务已完成！');
                    stopAutomatedSearch();
                    return;
                }

                if (searchState.needRest && !searchState.fallbackMode) {
                    startResting();
                } else if (callback) {
                    callback();
                }
            }, 1500);
        } else {
            if (!currentProgress.total && !currentProgress.completed) {
                enableFallbackSearchMode('无法打开侧边栏，将按 ' + config.fallbackSearchCount + ' 次搜索');
            }
            updateStatus('无法打开侧边栏检查进度，已按次数继续');
            if (callback) callback();
        }
    }

    // 等待下一次搜索
    function waitForNextSearch() {
        updateStatus('等待下一次搜索...');
        startCountdown(config.waitTime, 'waiting', performNextSearch);
    }

    // 执行下一次搜索
    function performNextSearch() {
        // 如果不在搜索状态，停止
        if (!isSearching) return;

        // 计算还需要搜索的次数
        const remainingSearches = currentProgress.total - currentProgress.current;
        if (remainingSearches <= 0 || currentProgress.completed) {
            showCompletionNotification();
            updateStatus('搜索任务已完成！');
            stopAutomatedSearch();
            return;
        }

        // 先更新搜索词列表，然后再获取搜索词
        updateStatus('获取最新搜索词...');
        getSearchTermsFromMainDoc();

        // 获取搜索词
        const searchTermObj = getSearchTerm();

        if (!searchTermObj) {
            updateStatus('没有可用的搜索词，获取数据...');
            getRewardsData(() => {
                // 如果仍然没有搜索词，尝试使用保底搜索词
                ensureFallbackSearchTerms();

                // 重新检查是否有搜索词
                const newSearchTermObj = getSearchTerm();
                if (newSearchTermObj) {
                    // 有搜索词，重新执行搜索
                    setTimeout(performNextSearch, 1000);
                } else {
                    updateStatus('无法获取搜索词，停止搜索');
                    stopAutomatedSearch();
                }
            });
            return;
        }

        const { term, source } = searchTermObj;
        updateStatus(`正在搜索: ${term} (${source}搜索词) [剩余:${remainingSearches}]`);

        // 整页跳转前先记下次数，submit 失败再回退
        const useFallbackCount = searchState.fallbackMode || !currentProgress.total;
        if (useFallbackCount) {
            advanceFallbackProgress();
        }

        if (performSearch(term)) {
            // 搜索成功后模拟滚动
            setTimeout(() => {
                simulateScrolling(() => {
                    // 滚动结束后检查进度
                    checkProgress(() => {
                        // 检查进度后等待下一次搜索
                        waitForNextSearch();
                    });
                });
            }, 2000);
        } else {
            if (useFallbackCount && currentProgress.current > 0) {
                currentProgress.current -= 1;
                currentProgress.lastChecked = currentProgress.current;
                currentProgress.completed = false;
                updateProgressDisplay();
                updateAndSaveState();
            }
            updateStatus('搜索失败，请检查网页状态');
            // 3秒后重试
            setTimeout(performNextSearch, 3000);
        }
    }

    // 开始自动搜索
    function startAutomatedSearch() {
        // 首先检查是否有搜索词，如果没有就获取
        if (mainPageSearchTerms.length === 0 && iframeSearchTerms.length === 0) {
            updateStatus('获取搜索词中...');
            getRewardsData(() => {
                if (mainPageSearchTerms.length === 0 && iframeSearchTerms.length === 0) {
                    // 使用保底搜索词
                    ensureFallbackSearchTerms();
                }
                if (mainPageSearchTerms.length === 0 && iframeSearchTerms.length === 0) {
                    alert('没有搜索词，无法开始搜索');
                    return;
                }
                // 有搜索词，开始搜索
                startSearchProcess();
            });
        } else {
            startSearchProcess();
        }
    }

    // 开始搜索流程
    function startSearchProcess() {
        isSearching = true;
        searchState.needRest = false;
        currentProgress.noProgressCount = 0;  // 重置未增加计数
        usedSearchTerms = []; // 重置已使用搜索词列表
        document.getElementById('start-search-btn').textContent = '停止搜索';
        document.getElementById('start-search-btn').style.backgroundColor = '#d83b01';

        if (!currentProgress.total && !currentProgress.completed) {
            enableFallbackSearchMode('无法从侧栏获取积分，将按 ' + config.fallbackSearchCount + ' 次搜索');
        }

        updateStatus(searchState.fallbackMode
            ? `无法从侧栏获取积分，开始按 ${config.fallbackSearchCount} 次搜索`
            : '自动搜索已开始...');

        // 保存状态
        saveState();

        // 计算还需要搜索的次数
        const remainingSearches = currentProgress.total - currentProgress.current;
        if (remainingSearches <= 0 || currentProgress.completed) {
            updateStatus('搜索任务已完成！');
            stopAutomatedSearch();
            return;
        }

        // 开始第一次搜索
        performNextSearch();
    }

    // 恢复状态
    function restoreState() {
        const savedState = loadState();
        if (savedState && savedState.isSearching) {
            // 恢复变量状态
            currentProgress = savedState.currentProgress || currentProgress;
            searchState.fallbackMode = !!savedState.fallbackMode;
            usedSearchTerms = savedState.usedSearchTerms || [];
            mainPageSearchTerms = savedState.mainPageSearchTerms || [];
            iframeSearchTerms = savedState.iframeSearchTerms || [];

            // 更新UI显示
            updateProgressDisplay();

            updateStatus('检测到之前的搜索任务，正在恢复...');
            
            // 延迟启动自动搜索，给页面时间初始化
            setTimeout(() => {
                if (!currentProgress.completed) {
                    console.log('恢复搜索状态，继续之前的搜索任务');
                    startSearchProcess();
                } else {
                    updateStatus('之前的搜索任务已完成');
                    clearState();
                }
            }, 3000);
            
            return true;
        }
        return false;
    }

    // 在关键操作时保存状态
    function updateAndSaveState() {
        if (isSearching) {
            saveState();
        }
    }

    // 停止自动搜索
    function stopAutomatedSearch() {
        // 清除倒计时
        if (countdownTimer) {
            clearInterval(countdownTimer);
            countdownTimer = null;
        }

        isSearching = false;
        searchState.currentAction = 'idle';
        searchState.needRest = false;
        if (searchState.fallbackMode) {
            currentProgress.current = 0;
            currentProgress.total = 0;
            currentProgress.lastChecked = 0;
            currentProgress.completed = false;
            searchState.fallbackMode = false;
            updateProgressDisplay();
        }
        currentProgress.noProgressCount = 0;  // 重置未增加计数
        usedSearchTerms = []; // 重置已使用搜索词列表
        updateCountdown(0, '');

        // 清除持久化状态
        clearState();

        document.getElementById('start-search-btn').textContent = '开始自动搜索';
        document.getElementById('start-search-btn').style.backgroundColor = '#0078d4';
        updateStatus('搜索已停止');
    }

    // 显示完成通知
    function showCompletionNotification() {
        // 创建通知元素
        const notification = document.createElement('div');
        notification.style.cssText = `
            position: fixed;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            background-color: #0078d4;
            color: white;
            padding: 20px;
            border-radius: 5px;
            box-shadow: 0 4px 8px rgba(0,0,0,0.2);
            z-index: 10001;
            text-align: center;
            font-size: 16px;
        `;
        const notifTitle = document.createElement('div');
        notifTitle.style.cssText = 'font-weight: bold; margin-bottom: 10px; font-size: 18px;';
        notifTitle.textContent = '任务完成！';
        notification.appendChild(notifTitle);

        const notifBody = document.createElement('div');
        notifBody.textContent = `已完成所有 ${currentProgress.total} 次搜索任务`;
        notification.appendChild(notifBody);

        const closeBtn2 = document.createElement('button');
        closeBtn2.id = 'notification-close';
        closeBtn2.textContent = '关闭';
        closeBtn2.style.cssText = 'margin-top: 15px; padding: 5px 15px; background-color: white; color: #0078d4; border: none; border-radius: 3px; cursor: pointer;';
        notification.appendChild(closeBtn2);
        document.body.appendChild(notification);

        // 添加关闭按钮事件
        document.getElementById('notification-close').addEventListener('click', function () {
            notification.remove();
        });

        // 10秒后自动关闭
        setTimeout(() => {
            if (document.body.contains(notification)) {
                notification.remove();
            }
        }, 10000);
    }

    // 开始倒计时
    function startCountdown(seconds, action, callback) {
        // 清除现有倒计时
        if (countdownTimer) {
            clearInterval(countdownTimer);
            countdownTimer = null;
        }

        searchState.currentAction = action;
        searchState.countdown = seconds;

        updateCountdown(seconds, action);

        countdownTimer = setInterval(() => {
            searchState.countdown--;
            updateCountdown(searchState.countdown, action);

            if (searchState.countdown <= 0) {
                clearInterval(countdownTimer);
                countdownTimer = null;
                if (callback) callback();
            }
        }, 1000);
    }

    // re-apply theme colors to all UI elements
    function applyTheme() {
        const theme = getTheme();
        const container = document.getElementById('rewards-helper-container');
        if (!container) return;

        container.style.backgroundColor = theme.bg;
        container.style.color = theme.text;
        container.style.borderColor = theme.border;

        // header border
        const header = container.querySelector('div');
        if (header) header.style.borderBottomColor = theme.border;

        // status text
        const status = document.getElementById('search-status');
        if (status) status.style.color = theme.textSecondary;

        // countdown
        const cd = document.getElementById('countdown');
        if (cd) cd.style.color = theme.accent;

        // config section border
        const configSection = document.getElementById('rewards-config-section');
        if (configSection) configSection.style.borderTopColor = theme.border;

        // inputs
        container.querySelectorAll('input[type="number"]').forEach(input => {
            input.style.background = theme.inputBg;
            input.style.color = theme.text;
            input.style.borderColor = theme.inputBorder;
        });

        // start button (only update if not in searching state)
        const btn = document.getElementById('start-search-btn');
        if (btn && !isSearching) {
            btn.style.backgroundColor = theme.accent;
        }
    }

    // 在页面加载完成后初始化
    window.addEventListener('load', function () {
        console.log('Microsoft Rewards 助手已加载');
        createUI();
        // 初始应用折叠状态
        applyCollapseState();

        // watch for dark mode changes
        const observer = new MutationObserver(() => applyTheme());
        observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class', 'data-darkmode'] });
        observer.observe(document.body, { attributes: true, attributeFilter: ['class'] });
        window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', applyTheme);
        
        // 尝试恢复之前的搜索状态
        setTimeout(() => {
            const restored = restoreState();
            if (!restored) {
                // 如果没有恢复状态，正常获取数据
                setTimeout(() => {
                    getRewardsData();
                }, 1000);
            }
        }, 1000);
    });
})();